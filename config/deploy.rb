# config valid only for current version of Capistrano
lock "3.8.2"

set :application, 'hkn-rails'
set :repo_url, 'git@github.com:compserv/hkn-rails.git'

set :rails_env, 'production'

set :conditionally_migrate, true

set :deploy_via, :remote_cache

set :ssh_options, forward_agent: true

# Rollbar config
set :rollbar_env,  proc { fetch :stage }
set :rollbar_role, proc { :app }
set :rollbar_user, `git config user.name`
# TODO: set rollbar token for deploy reporting
# set :rollbar_token, 'token goes here'

# Use bundler with multiple cores
set :bundle_jobs, 8

# Show more verbose bundler output (default is --deployment --quiet)
set :bundle_flags, '--deployment'

# Default branch is :master
# ask :branch, `git rev-parse --abbrev-ref HEAD`.chomp

# Default deploy_to directory is /var/www/my_app_name
# set :deploy_to, '/home/h/hk/hkn/hkn-rails'

# Default value for :format is :airbrussh.
# set :format, :airbrussh

# You can configure the Airbrussh format using :format_options.
# These are the defaults.
# set :format_options, command_output: true, log_file: "log/capistrano.log", color: :auto, truncate: :auto

# Default value for :pty is false
# set :pty, true

# Default value for :linked_files is []
set :linked_files, %w[config/database.yml config/secrets.yml]

# Default value for linked_dirs is []
set :linked_dirs, %w[log tmp/pids tmp/cache tmp/sockets]

# Default value for default_env is {}
# set :default_env, { path: "/opt/ruby/bin:$PATH" }

# Default value for local_user is ENV['USER']
# set :local_user, -> { `git config user.name`.chomp }

# Default value for keep_releases is 5
# set :keep_releases, 5

namespace :deploy do
  desc "Zero-downtime restart of Unicorn"
  task :restart do
    on roles(:all) do |host|
      execute :systemctl, '--user restart hkn-rails.service'
    end
  end

  desc "Start unicorn"
  task :start do
    on roles(:all) do |host|
      execute :systemctl, '--user start hkn-rails.service'
    end
  end

  desc "Stop unicorn"
  task :stop do
    on roles(:all) do |host|
      execute :systemctl, '--user stop hkn-rails.service'
    end
  end

  after :publishing, :restart
end
