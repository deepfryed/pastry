# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = "pastry"
  s.version = "0.3.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Bharanee Rathna"]
  s.date = "2013-03-13"
  s.description = "thin runner that forks and supports binding to single socket"
  s.email = "deepfryed@gmail.com"
  s.executables = ["pastry"]
  s.extra_rdoc_files = ["README.rdoc"]
  s.files = ["lib/pastry.rb", "README.rdoc", "bin/pastry"]
  s.homepage = "http://github.com/deepfryed/pastry"
  s.require_paths = ["lib"]
  s.rubygems_version = "1.8.24"
  s.summary = "thin runner that supports forking"

  if s.respond_to? :specification_version then
    s.specification_version = 3

    if Gem::Version.new(Gem::VERSION) >= Gem::Version.new('1.2.0') then
      s.add_runtime_dependency(%q<thin>, [">= 0"])
    else
      s.add_dependency(%q<thin>, [">= 0"])
    end
  else
    s.add_dependency(%q<thin>, [">= 0"])
  end
end
