ROS Index
=========

A simple static index for known ROS packages. It builds in jekyll with a plugin
to clone repositories containing ROS packages, scrapes them for information,
and uses client-side javascript for quick searching and visualization.

[ROS Index](http://rosindex.github.io/)

* [About](http://rosindex.github.io/about)
* [Design](http://rosindex.github.io/about/design)
* [Development](http://rosindex.github.io/about/development)
* [Contribute](http://rosindex.github.io/contribute)

[![Stories in Ready](https://badge.waffle.io/rosindex/rosindex.github.io.svg?label=ready&title=Ready)](http://waffle.io/rosindex/rosindex.github.io)

## Building

### Ruby 2.2 on Ubuntu 12.04

```
sudo apt-get update
sudo apt-get install curl git mercurial nodejs
curl -L https://get.rvm.io | bash -s stable
# if this fails, add the PGP key and run again
source ~/.rvm/scripts/rvm
rvm requirements
rvm install ruby
rvm rubygems current
```

### Node.js on Ubuntu 12.04

```
sudo apt-get install python-software-properties
sudo apt-add-repository ppa:chris-lea/node.js
sudo apt-get update
sudo apt-get install nodejs
```

### Ruby Requirements

```
gem install bundler
```

### Clone Source and Install Gems

```
git clone git@github.com:rosindex/rosindex.github.io.git --recursive
cd rosindex.github.io
bundle install
```

### Build the Devel (Tiny) Version

```
rake build:devel
```



