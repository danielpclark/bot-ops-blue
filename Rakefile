# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"
require "fileutils"

ROOT = File.expand_path(__dir__)
CRATE = File.join(ROOT, "ext", "bot_ops_native")
NATIVE_DIR = File.join(ROOT, "lib", "bot_ops", "native")
HOST_OS = RbConfig::CONFIG["host_os"]
MAC = HOST_OS =~ /darwin/ ? true : false
WINDOWS = HOST_OS =~ /mswin|mingw/ ? true : false
BUILT = MAC ? "libbot_ops_native.dylib" : (WINDOWS ? "bot_ops_native.dll" : "libbot_ops_native.so")
INSTALLED = File.join(NATIVE_DIR, "bot_ops_native.#{MAC ? 'bundle' : 'so'}")

def cargo?
  system("cargo", "--version", out: File::NULL, err: File::NULL)
end

desc "One-time setup: install gems and build the native window (needs Rust)"
task :setup do
  unless cargo?
    abort <<~MSG
      Rust toolchain not found. Install it (one command, all platforms):
        https://rustup.rs
      then re-run: bundle exec rake setup
    MSG
  end
  sh "bundle install"
  Rake::Task[:compile].invoke
  puts
  puts "Setup complete. Start the dashboard with: bundle exec rake run"
end

desc "Build the Rust extension with cargo and install it under lib/bot_ops/native"
task :compile do
  abort "cargo not found; install Rust from https://rustup.rs" unless cargo?
  sh "cargo", "build", "--release", "--manifest-path", File.join(CRATE, "Cargo.toml")
  FileUtils.mkdir_p(NATIVE_DIR)
  FileUtils.cp(File.join(CRATE, "target", "release", BUILT), INSTALLED)
  puts "Installed #{INSTALLED}"
end

desc "Create the collector token (~/.config/bot-ops-blue/token) if it does not exist"
task :token do
  require "securerandom"
  path = File.join(Dir.home, ".config", "bot-ops-blue", "token")
  unless File.exist?(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, SecureRandom.hex(24) + "\n", perm: 0o600)
  end
  puts "Token: #{path}"
end

desc "Run the Bot Ops Blue desktop app"
task :run do
  Rake::Task[:compile].invoke unless File.exist?(INSTALLED)
  ruby File.join(ROOT, "bot_ops_blue.rb")
end

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

desc "Render every page to SVG in tmp/preview (no display or Rust needed)"
task :preview do
  $LOAD_PATH.unshift(File.join(ROOT, "lib"))
  require "bot_ops"
  out = File.join(ROOT, "tmp", "preview")
  FileUtils.mkdir_p(out)
  host = BotOps::PreviewHost.new
  store = BotOps::Store.new
  scene = BotOps::Scene.new(store, host)
  store.apply(type: "snapshot", snapshot: BotOps::Probe.new.snapshot, local: true)
  BotOps::Layout::NAV.each do |key, _name, _glyph|
    store.page = key
    File.write(File.join(out, "#{key}.svg"), scene.build.to_svg)
  end
  puts "Wrote #{BotOps::Layout::NAV.size} pages to #{out}"
end

desc "Remove build artifacts"
task :clean do
  sh "cargo", "clean", "--manifest-path", File.join(CRATE, "Cargo.toml") if cargo?
  FileUtils.rm_rf(NATIVE_DIR)
  FileUtils.rm_rf(File.join(ROOT, "tmp"))
end

task default: :test
