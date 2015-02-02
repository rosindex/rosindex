desc 'Publishing the website via rsync'

require 'git'

task :default => [:devel]

task :devel => [:"build:devel", :"serve:devel"]
task :deploy => [:"build:deploy", :"serve:deploy"]

namespace :build do

  task :devel do
    puts "Generating local rosindex..."
    sh "bundle exec jekyll build --trace --config=_config.yml,_config_devel.yml"
  end

  task :deploy do
    puts 'Generating deployment rosindex (this could take a while)...'
    sh "bundle exec jekyll build --trace --config=_config.yml"
  end

end

namespace :serve do

  task :deploy do
    puts "Serving local rosindex..."
    sh "bundle exec jekyll serve --trace --config=_config.yml --skip-initial-build"
  end

  task :devel do
    puts "Serving local rosindex..."
    sh "bundle exec jekyll serve --trace --config=_config.yml,_config_devel.yml --skip-initial-build"
  end


end

task :publish do
  #g = Git.open('.')
  #g.branch('master').delete
  #sh "git push -f origin master"
  puts 'ROS Index published!'
end

