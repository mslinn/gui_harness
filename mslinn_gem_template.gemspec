require_relative 'lib/mslinn_gem_template/version'

Gem::Specification.new do |spec|
  host = 'https://github.com/mslinn/mslinn_gem_template'

  spec.authors               = ['Mike Slinn']
  spec.bindir                = 'exe'
  spec.executables           = []
  spec.description           = <<~END_DESC
    Template project for new Ruby gems.
  END_DESC
  spec.email                 = ['mslinn@mslinn.com']
  spec.files                 = Dir['.rubocop.yml', 'LICENSE.*', 'Rakefile', '{lib,spec}/**/*', '*.gemspec', '*.md']
  spec.homepage              = 'https://mslinn.com'
  spec.license               = 'MIT'
  spec.metadata = {
    'allowed_push_host' => 'https://rubygems.org',
    'bug_tracker_uri'   => "#{host}/issues",
    'changelog_uri'     => "#{host}/CHANGELOG.md",
    'homepage_uri'      => spec.homepage,
    'source_code_uri'   => host,
  }
  spec.name                 = 'mslinn_gem_template'
  spec.platform             = Gem::Platform::RUBY
  spec.post_install_message = <<~END_MESSAGE

    Thanks for installing #{spec.name}!

  END_MESSAGE
  spec.require_paths         = ['lib']
  spec.required_ruby_version = '>= 3.4'
  spec.summary               = 'Template for Ruby gems'
  spec.version               = MslinnGemTemplate::VERSION

  spec.add_dependency 'colorator'
end
