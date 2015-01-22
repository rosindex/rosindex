---
layout: page
title: Development
permalink: /about/development/
---

# ROS Index Development

ROS Index is a statically-generated website which is composed of four main components:

1. A Jekyll backbone
2. A Jekyll Ruby plugin which clones and analyzes ROS repositories
3. HTML templates for displaying content
4. Build-side and client-side javascript for searching the index

## Building ROSIndex

### System Requirements:

* ruby 1.9
* subversion 1.8
  * with SWIG ruby bindings and serf (`./configure --with-serf`)
* git
* mercurial

### Ruby Requirements:

### Getting the ROS Index Source

#### Cloning

```
git submodule init
git submodule update
```

## Building

```
rake build:devel
rake serve:devel
```

```
rake build:deploy
rake serve:deploy
```

## Deployment

Since this needs to do a lot of heavy lifting to generate the site, it needs to
be deployed from a fully-equipped environment.

```
git checkout source
rake build:deploy
pushd _deploy
git commit -am "deploy"
git push origin master
popd
git commit -am "deployed"
git push origin source
```
