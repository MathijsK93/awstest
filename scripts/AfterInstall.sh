#!/bin/bash
cd /webapps/rails
RAILS_ENV=production bundle install --path vendor/bundle
RAILS_ENV=production bundle exec rake assets:clobber
RAILS_ENV=production bundle exec rake assets:precompile
