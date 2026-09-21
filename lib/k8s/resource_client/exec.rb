# frozen_string_literal: true

module K8s
  class ResourceClient
    # Executes commands in a container over the API server's exec websocket.
    #
    # Kubernetes multiplexes the exec streams down one socket: byte 0 of every
    # frame is the channel (1 stdout, 2 stderr, 3 status) and the rest is
    # payload. Frames must be demultiplexed as they arrive, because concatenating
    # them whole leaves a channel byte at each boundary -- JSON that parses or
    # not depending on how the server happened to split the reply -- and once
    # joined the boundaries are gone, so it cannot be undone afterwards.
    #
    # Channel 3 carries the exit status, but only the v4 subprotocol makes it
    # machine-readable, so we negotiate v4 and fall back to parsing v1's prose.
    module Exec
      require "eventmachine"
      require "faye/websocket"
      require "json"
      require "termios"
      require "tempfile"

      SUBPROTOCOL = "v4.channel.k8s.io"
      STDOUT_CHANNEL = 1
      STDERR_CHANNEL = 2
      STATUS_CHANNEL = 3
      DEFAULT_TIMEOUT = 60

      class Error < StandardError; end

      # Raised when the command ran and exited non-zero. Carries the streams so
      # a caller can log stderr without re-running the command.
      class CommandFailed < Error
        attr_reader :result

        def initialize(result, command)
          @result = result
          detail = result.stderr.strip
          detail = result.stdout.strip if detail.empty?
          super("#{Exec.program(command)} exited #{result.exit_code}: #{detail}")
        end
      end

      Result = Struct.new(:stdout, :stderr, :exit_code, keyword_init: true) do
        def success?
          exit_code.zero?
        end

        # stdout, or raise CommandFailed. For callers that want an exception
        # rather than a status to check.
        def value!(command = nil)
          raise CommandFailed.new(self, command) unless success?

          stdout
        end

        def to_s
          stdout
        end
      end

      # EventMachine's reactor is a process-wide singleton. Calling EM.run when
      # it is already up does not raise -- it runs the block on the calling
      # thread and returns immediately, which would hand back an empty result.
      # So own one reactor thread for the process and schedule onto it. We never
      # call EM.stop: the reactor may belong to someone else.
      REACTOR_LOCK = Mutex.new

      def self.schedule(&block)
        unless EM.reactor_running?
          REACTOR_LOCK.synchronize do
            unless EM.reactor_running?
              up = Queue.new
              Thread.new { EM.run { up << true } }.name = "k8s-ruby-exec-reactor"
              up.pop
            end
          end
        end
        EM.next_tick(&block)
      end

      # @param status [String, nil] the raw channel 3 payload
      def self.exit_code(status)
        raise Error, "exec closed without a status frame" if status.nil?

        doc = JSON.parse(status)
        return 0 if doc["status"] == "Success"

        cause = doc.dig("details", "causes")&.find { |c| c["reason"] == "ExitCode" }
        cause ? cause["message"].to_i : 1
      rescue JSON::ParserError
        # v1 subprotocol: "command terminated with non-zero exit code: exit status 7"
        status[/exit (?:status|code) (\d+)/, 1]&.to_i || 1
      end

      # Names the command in an error without repeating its arguments, which
      # routinely carry credentials (curl -u, psql, redis-cli -a).
      def self.program(command)
        argv = [command].flatten.compact
        return "command" if argv.empty?

        return argv.first.to_s if argv.length == 1

        count = argv.length - 1
        "#{argv.first} (#{count} #{count == 1 ? 'arg' : 'args'})"
      end

      # Command output is normally text. Tag it UTF-8 so callers can parse it,
      # but leave genuinely binary output alone rather than mislabel it.
      def self.text(buffer)
        buffer.force_encoding(Encoding::UTF_8)
        buffer.valid_encoding? ? buffer : buffer.force_encoding(Encoding::BINARY)
      end

      def self.included(base)
        base.include(InstanceMethods)
        base.include(Logging)
      end

      module InstanceMethods
        # Executes a command in a container and waits for it to finish.
        #
        # @param name [String] name of the pod
        # @param command [Array<String>, String] command and arguments
        # @param container [String, nil] container name; the pod's first when nil
        # @param namespace [String]
        # @param stdin [Boolean] stream stdin to the container (needs tty)
        # @param stdout [Boolean] stream stdout from the container
        # @param stderr [Boolean] stream stderr from the container
        # @param tty [Boolean] allocate a tty. Needs a controlling terminal, so
        #   only for interactive use -- never in a job. Output goes to $stdout.
        # @param timeout [Numeric] seconds to wait before closing the socket
        # @yield [String, Integer] each frame's payload and channel, as it arrives
        # @return [Result] stdout, stderr and exit code. nil when tty or a block
        #   is given, since neither buffers.
        # @raise [Error] on timeout, socket error, or a close with no status
        #
        # @example
        #   pods.exec(name: "web-0", command: %w[cat /etc/hostname]).value!
        def exec(name:, command:, container: nil, namespace: @namespace,
                 stdin: false, stdout: true, stderr: true, tty: false,
                 timeout: Exec::DEFAULT_TIMEOUT, &block)
          query = { command: [command].flatten }
          query[:container] = container if container
          query.merge!(stdin: !!stdin, stdout: !!stdout, stderr: !!stderr, tty: !!tty)
          exec_path = path(name, namespace: namespace, subresource: "exec")

          # This blocks the calling thread until the command finishes, so from
          # inside the reactor it would deadlock: the tick that drives the
          # socket cannot run while its own thread waits here. Fail fast rather
          # than hang until the timeout.
          if EM.reactor_running? && EM.reactor_thread == Thread.current
            raise Exec::Error, "exec blocks until the command finishes, so it cannot be called " \
                               "from inside the EventMachine reactor thread"
          end

          out = +"".b
          err = +"".b
          status = nil
          failure = nil
          finished = Queue.new

          original_term = (Termios.tcgetattr($stdin) if tty)
          if original_term
            raw = original_term.dup
            raw.lflag &= ~(Termios::ECHO | Termios::ICANON)
            Termios.tcsetattr($stdin, Termios::TCSANOW, raw)
          end

          Exec.schedule do
            ws = @transport.build_ws_conn(exec_path, query, protocols: [Exec::SUBPROTOCOL])
            timer = EM.add_timer(timeout) do
              failure ||= Exec::Error.new("exec timed out after #{timeout}s: #{Exec.program(command)}")
              ws.close
            end

            ws.on :message do |event|
              frame = event.data
              frame = frame.pack("C*") unless frame.is_a?(String)
              channel = frame.getbyte(0)
              payload = frame.byteslice(1..) || ""
              next if payload.empty?

              case channel
              when Exec::STATUS_CHANNEL then status = payload
              else
                if block then block.call(payload, channel)
                elsif tty then $stdout.write(payload)
                elsif channel == Exec::STDERR_CHANNEL then err << payload
                else out << payload
                end
              end
            end

            if stdin && tty
              EM.open_keyboard(Module.new do
                define_method(:receive_data) { |input| ws.send([0] + input.unpack("C*")) }
              end)
            end

            ws.on(:error) { |event| failure ||= Exec::Error.new(event.message) }
            ws.on(:close) do
              EM.cancel_timer(timer)
              finished << true
            end
          end

          # The timer closes the socket, which fires :close. The wider deadline
          # is only so a socket that never closes cannot wedge the caller.
          wedged = finished.pop(timeout: timeout + 5).nil?
          Termios.tcsetattr($stdin, Termios::TCSANOW, original_term) if original_term

          raise failure if failure
          raise Exec::Error, "exec never closed: #{Exec.program(command)}" if wedged
          return if tty || block

          Result.new(
            stdout: Exec.text(out),
            stderr: Exec.text(err),
            exit_code: Exec.exit_code(status)
          )
        end
      end
    end
  end
end
