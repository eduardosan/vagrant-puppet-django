# -*- mode: ruby -*-
# vi: set ft=ruby :

Exec { path => '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' }

include timezone
include user
include apt
include nginx
include uwsgi
include postgresql
include python
include virtualenv
include pildeps
include software

class timezone {
  package { "tzdata":
    ensure => latest,
    require => Class['apt']
  }

  file { "/etc/localtime":
    require => Package["tzdata"],
    source => "file:///usr/share/zoneinfo/${tz}",
  }
}

class user {
  exec { 'add user':
    command => "sudo useradd -m -G sudo -s /bin/bash ${user}",
    unless => "id -u ${user}"
  }

  exec { 'set password':
    command => "echo \"${user}:${password}\" | sudo chpasswd",
    require => Exec['add user']
  }

  # Prepare user's project directories
  file { ["/home/${user}/virtualenvs",
          "/home/${user}/public_html",
          "/home/${user}/public_html/${domain_name}",
          "/home/${user}/public_html/${domain_name}/static"
          ]:
    ensure => directory,
    owner => "${user}",
    group => "${user}",
    require => Exec['add user'],
    before => File['media dir']
  }

  file { 'media dir':
    path => "/home/${user}/public_html/${domain_name}/media",
    ensure => directory,
    owner => "${user}",
    group => 'www-data',
    mode => 0775,
    require => Exec['add user']
  }
}

class nginx {
  package { 'nginx':
    ensure => latest,
    require => Class['apt']
  }

  service { 'nginx':
    ensure => running,
    enable => true,
    require => Package['nginx']
  }

  file { '/etc/nginx/sites-enabled/default':
    ensure => absent,
    require => Package['nginx']
  }

  file { 'sites-available config':
    path => "/etc/nginx/sites-available/${domain_name}",
    ensure => file,
    content => template("${inc_file_path}/nginx/nginx.conf.erb"),
    require => Package['nginx']
  }

  file { "/etc/nginx/sites-enabled/${domain_name}":
    ensure => link,
    target => "/etc/nginx/sites-available/${domain_name}",
    require => File['sites-available config'],
    notify => Service['nginx']
  }
}

class uwsgi {
  $sock_dir = '/var/run/uwsgi' # Without a trailing slash
  $uwsgi_user = $user
  $uwsgi_group = $user

  package { 'uwsgi':
    ensure => latest,
    provider => pip,
    require => Class['python']
  }

  service { 'uwsgi':
    ensure => running,
    enable => true,
    require => File['apps-enabled config']
  }

  # Prepare directories
  file { ['/var/log/uwsgi', '/etc/uwsgi', '/etc/uwsgi/apps-available', '/etc/uwsgi/apps-enabled']:
    ensure => directory,
    require => Package['uwsgi'],
    before => File['apps-available config']
  }

  # Prepare a directory for sock file
  file { [$sock_dir]:
    ensure => directory,
    owner => "${uwsgi_user}",
    group => "${uwsgi_user}",
    require => Package['uwsgi']
  }

  # Upstart file
  file { '/etc/init/uwsgi.conf':
    ensure => file,
    source => "${inc_file_path}/uwsgi/uwsgi.conf",
    require => Package['uwsgi']
  }

  # Vassals ini file
  file { 'apps-available config':
    path => "/etc/uwsgi/apps-available/${project}.ini",
    ensure => file,
    content => template("${inc_file_path}/uwsgi/uwsgi.ini.erb")
  }

  file { 'apps-enabled config':
    path => "/etc/uwsgi/apps-enabled/${project}.ini",
    ensure => link,
    target => "/etc/uwsgi/apps-available/${project}.ini",
    require => File['apps-available config']
  }

  # Diretório de logs
  file { ["/var/log/${project}"]:
    ensure => directory,
    owner => "${uwsgi_user}",
    group => "${uwsgi_user}",
    require => Package['uwsgi']
  }

}

class postgresql {

  class { 'postgresql::globals':
    version             => '9.4',
    manage_package_repo => true,
    encoding            => "UTF8",
    #locale              => "pt_BR.UTF-8",
    # TODO: remove the next line after PostgreSQL 9.4 release
    postgis_version     => '2.1',
  }->
  class { 'postgresql::server':
    listen_addresses => '127.0.0.1',
    port   => 5432,
    ip_mask_allow_all_users    => '127.0.0.1/32',
  }

  postgresql::server::role { "${user}":
    superuser => true,
    require   => Class['postgresql::server']
  }

  postgresql::server::db { "${db_name}":
    encoding => 'UTF8',
    user => "${db_user}",
    owner => "${db_user}",
    password => postgresql_password("${db_user}", "${db_password}"),
    require  => Class['postgresql::server']
  }

  postgresql::server::role { "${db_user}":
    createdb => true,
    require  => Class['postgresql::server']
  }

  package { 'libpq-dev':
    ensure => installed
  }

  package { 'postgresql-contrib':
    ensure  => installed,
    require => Class['postgresql::server'],
  }
}


class python {
  package { 'curl':
    ensure => latest,
    require => Class['apt']
  }

  package { 'python':
    ensure => latest,
    require => Class['apt']
  }

  package { 'python-dev':
    ensure => latest,
    require => Class['apt']
  }

  exec { 'install-pip':
    command => 'curl https://bootstrap.pypa.io/get-pip.py | python',
    require => Package['python', 'curl']
  }
}

class virtualenv {
  package { 'virtualenv':
    ensure => latest,
    provider => pip,
    require => Class['python', 'user']
  }

  exec { 'create virtualenv':
    command => "virtualenv --always-copy ${domain_name}",
    cwd => "/home/${user}/virtualenvs",
    #user => $user,
    require => Package['virtualenv']
  }

  # Cria estrutura de diretórios do Projeto
  file { "virtualenv dir":
    path => "/home/${user}/virtualenvs/${domain_name}",
    ensure => directory,
    owner => "${user}",
    group => "${user}",
    recurse => true,
    require => Exec['create virtualenv']
  }

  file { ["/home/${user}/virtualenvs/${domain_name}/src",
          "/home/${user}/virtualenvs/${domain_name}/src/requirements",
          "/home/${user}/virtualenvs/${domain_name}/src/etc"
          ]:
    ensure => directory,
    owner => "${user}",
    group => "${user}",
    require => File['virtualenv dir'],
    before => File['requirements base']
  }

  file { "requirements base":
    path => "/home/${user}/virtualenvs/${domain_name}/src/requirements/base.txt",
    ensure => file,
    owner => "${user}",
    group => "${user}",
    mode => 0644,
    source => "${inc_file_path}/virtualenv/requirements.txt"
  }
}

class pildeps {
  package { ['python-imaging', 'libjpeg-dev', 'libfreetype6-dev']:
    ensure => latest,
    require => Class['apt'],
    before => Exec['pil png', 'pil jpg', 'pil freetype']
  }

  exec { 'pil png':
    command => 'sudo ln -s /usr/lib/`uname -i`-linux-gnu/libz.so /usr/lib/',
    unless => 'test -L /usr/lib/libz.so'
  }

  exec { 'pil jpg':
    command => 'sudo ln -s /usr/lib/`uname -i`-linux-gnu/libjpeg.so /usr/lib/',
    unless => 'test -L /usr/lib/libjpeg.so'
  }

  exec { 'pil freetype':
    command => 'sudo ln -s /usr/lib/`uname -i`-linux-gnu/libfreetype.so /usr/lib/',
    unless => 'test -L /usr/lib/libfreetype.so'
  }
}

class software {
  package { 'git':
    ensure => latest,
    require => Class['apt']
  }

  package { 'vim':
    ensure => latest,
    require => Class['apt']
  }

  package { 'libffi-dev':
    ensure => latest,
    require => Class['apt']
  }

  package { 'redis-server':
    ensure => latest,
    require => Class['apt']
  }
}
