#!/usr/bin/env sh

git branch -D master
git checkout -b master
git add -f _site
git commit -m "deploying"
git filter-branch --subdirectory-filter _site/ -f
git push -f origin master
git checkout source

