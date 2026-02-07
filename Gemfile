=begin
When building Gemfile.lock file, please add additional platforms to the file via the following command:

bundle lock \
  --add-platform aarch64-linux \
  --add-platform aarch64-linux-gnu \
  --add-platform aarch64-linux-musl \
  --add-platform arm-linux \
  --add-platform arm-linux-gnu \
  --add-platform arm-linux-musl \
  --add-platform arm64-darwin \
  --add-platform x64-mingw \
  --add-platform x64-mingw-ucrt \
  --add-platform x86-darwin \
  --add-platform x86-linux \
  --add-platform x86-linux-gnu \
  --add-platform x86-linux-musl \
  --add-platform x86-mingw \
  --add-platform x86-mingw-ucrt \
  --add-platform x86_64-darwin \
  --add-platform x86_64-linux \
  --add-platform x86_64-linux-gnu \
  --add-platform x86_64-linux-musl

This ensures that the lock file can be used by all platforms that are able to support it.
=end

source "https://rubygems.org"

git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }

group :development do
  gem "rspec"
  gem "rubocop"
  gem "guard"
  gem "guard-rspec"
  gem "webmock"
  gem "rack"
end

group :vscode do
  gem "rbs"
  gem "prism"
  gem "sorbet-runtime"
  gem "ruby-lsp"
end

group :gtk do
  gem "gtk3"
end

group :profanity do
  gem "curses"
end

gem "ascii_charts"
gem "base64"
gem "benchmark"
gem "concurrent-ruby"
gem "digest"
gem "drb"
gem "ffi"
gem "fiddle"
gem "fileutils"
gem "json"
gem "kramdown"
gem "logger"
gem "openssl"
gem "open-uri"
gem "os"
gem "ostruct"
gem "rake"
gem "redis"
gem "resolv"
gem "rexml"
gem "sequel"
gem "set"
gem "tempfile"
gem "terminal-table"
gem "time"
gem "tmpdir"
gem "tzinfo"
gem "tzinfo-data"
gem "webrick"
gem "win32ole", platforms: :windows
gem "yaml"
gem "zlib"

if Gem.win_platform?
  gem "sqlite3", platforms: :windows, force_ruby_platform: true
else
  gem "sqlite3"
end
