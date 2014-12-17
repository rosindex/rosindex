desc 'Publishing the website via rsync'

require 'git'

task :default => [:devel]

task :devel => [:"build:devel", :"serve:devel"]
task :deploy => [:"build:deploy", :"serve:deploy"]

lunr_cmd = "./node_modules/lunr-index-build/bin/lunr-index-build"
lunr_index_fields = " -r id -f baseurl -f url -f last_updated -f tags:100 -f name:100 -f version -f description:50 -f maintainers -f authors -f distro -f readme"

namespace :build do

  task :devel do
    puts "Generating local rosindex..."
    sh "jekyll build --trace --config=_config.yml,_config_devel.yml"
    sh lunr_cmd + " " + lunr_index_fields + " < _site/search.json > _site/index.json"
  end

  task :deploy do
    puts 'Generating deployment rosindex (this could take a while)...'
    sh "jekyll build --trace --destination=_deploy --config=_config.yml"
    sh lunr_cmd + " " + lunr_index_fields + " < _deploy/search.json > _deploy/index.json"
  end

end

namespace :serve do

  task :deploy do
    puts "Serving local rosindex..."
    sh "jekyll serve --trace --destination=_deploy --config=_config.yml --skip-initial-build"
  end

  task :devel do
    puts "Serving local rosindex..."
    sh "jekyll serve --trace --config=_config.yml,_config_devel.yml --skip-initial-build"
  end


end

task :publish do
  #g = Git.open('.')
  #g.branch('master').delete
  #sh "git push -f origin master"
  puts 'ROS Index published!'
end

