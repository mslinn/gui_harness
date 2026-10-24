require_relative 'lib/gui_harness/version'

Gem::Specification.new do |spec|
  host = 'https://github.com/mslinn/gui_harness'

  spec.authors               = ['Mike Slinn']
  spec.bindir                = 'exe'
  spec.executables           = []
  spec.description           = <<~END_DESC
    GUI automation harness for round-trip testing of real GUI applications.
  END_DESC
  spec.email                 = ['mslinn@mslinn.com']
  spec.files                 = Dir['.rubocop.yml', 'LICENSE.*', 'Rakefile', '{assets,lib,spec}/**/*', '*.gemspec', '*.md']
  spec.homepage              = 'https://mslinn.com'
  spec.license               = 'MIT'
  spec.metadata = {
    'allowed_push_host' => 'https://rubygems.org',
    'bug_tracker_uri'   => "#{host}/issues",
    'changelog_uri'     => "#{host}/CHANGELOG.md",
    'homepage_uri'      => spec.homepage,
    'source_code_uri'   => host,
  }
  spec.name                 = 'gui_harness'
  spec.platform             = Gem::Platform::RUBY
  spec.post_install_message = <<~END_MESSAGE

    Thanks for installing #{spec.name}!

  END_MESSAGE
  spec.require_paths         = ['lib']
  spec.required_ruby_version = '>= 3.4'
  spec.summary               = 'GUI harness for running and observing GUI apps in controlled tests'
  spec.version               = GuiHarness::VERSION

  spec.add_dependency 'colorator'
end
