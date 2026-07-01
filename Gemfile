source "https://rubygems.org"

git_source(:github) {|repo_name| "https://github.com/#{repo_name}" }

# Use forked excon with SOCKS5 support until upstream PR is merged
gem "excon", github: "aluminumio/excon", branch: "add-socks5-proxy-support"

# Specify your gem's dependencies in k8s-ruby.gemspec
gemspec
