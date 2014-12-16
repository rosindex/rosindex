desc 'Publishing the website via rsync'

require 'git'

task :default => [:devel]

task :devel => [:"devel:build", :"devel:serve"]
task :deploy => [:"deploy:build", :"deploy:serve"]

namespace :devel do

  task :build do
    puts "Generating local rosindex..."
    sh "jekyll build --trace --config=_config.yml,_config_devel.yml"
  end

  task :serve do
    puts "Serving local rosindex..."
    sh "jekyll serve --trace --config=_config.yml,_config_devel.yml --skip-initial-build"
  end

end

namespace :deploy do

  task :build do
    puts 'Generating deployment rosindex (this could take a while)...'
    sh "jekyll build --trace --destination=_deploy --config=_config.yml"
  end

  task :serve do
    puts "Serving local rosindex..."
    sh "jekyll serve --trace --destination=_deploy --config=_config.yml --skip-initial-build"
  end

  task :live do
    #g = Git.open('.')
    #g.branch('master').delete
    #sh "git push -f origin master"
    puts 'ROS Index deployed!'
  end

end
