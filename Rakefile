require 'date'
require 'pathname'
require 'rake'
require 'rake/clean'
require 'rake/testtask'

$rootdir = Pathname.new(__FILE__).dirname
$gemspec = Gem::Specification.new do |s|
  s.name              = "pastry"
  s.version           = "0.3.2"
  s.date              = Date.today
  s.authors           = "Bharanee Rathna"
  s.email             = "deepfryed@gmail.com"
  s.summary           = "thin runner that supports forking"
  s.description       = "thin runner that forks and supports binding to single socket"
  s.homepage          = "http://github.com/deepfryed/pastry"
  s.files             = Dir["lib/**/*.rb"] + %w(README.rdoc) + Dir["test/test_*.rb"]
  s.extra_rdoc_files  = %w(README.rdoc)
  s.executables       = %w(pastry)
  s.require_paths     = %w(lib)

  # TODO get the changes in http://github.com/deepfryed/eventmachine merged upstream.
  s.add_dependency 'thin'
end

desc 'Generate gemspec'
task :gemspec do
  $gemspec.date = Date.today
  File.open('%s.gemspec' % $gemspec.name, 'w') {|fh| fh.write($gemspec.to_ruby)}
end

desc 'tag release and build gem'
task :release => [:gemspec] do
  system("git tag -m 'version #{$gemspec.version}' v#{$gemspec.version}") or raise "failed to tag release"
  system("gem build #{$gemspec.name}.gemspec")
end
