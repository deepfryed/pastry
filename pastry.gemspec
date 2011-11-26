Gem::Specification.new do |s|
  s.name              = "pastry"
  s.version           = "0.1.0"
  s.date              = "2011-11-26"
  s.authors           = "Bharanee Rathna"
  s.email             = "deepfryed@gmail.com"
  s.summary           = "thin runner that supports forking"
  s.description       = "thin runner that forks and supports binding to single socket"
  s.homepage          = "http://github.com/deepfryed/pastry"
  s.files             = Dir["lib/**/*.rb"] + %w(README.rdoc) + Dir["test/test_*.rb"]
  s.extra_rdoc_files  = %w(README.rdoc)
  s.executables       = %w(pastry)
  s.require_paths     = %w(lib)

  # TODO get the em fixes in http://github.com/deepfryed/eventmachine accepted
  s.add_dependency 'thin'
end
