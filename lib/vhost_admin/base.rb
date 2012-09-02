require 'vhost_admin/version'
require 'thor'
require 'date'
require 'yaml'

class VhostAdmin::Base
  CONFIG_FILE = '.vhost_admin.conf'

  def initialize(options={})
    @config = load_config
    @crypt = options[:crypt] || false
  end
  def load_config
    unless File.exist?(config_file)
      create_config
      puts "configure file: #{config_file} was generated.\nPlease execute after edit it."
      exit
    end
      open(config_file) do |f|
      YAML.load(f.read)
    end
  end
  def create_config
    config = {
      'apache_conf_file'  => '/etc/httpd/conf/virtual/virtualhosts.conf',
      'home_dir_base'   => '/var/www/vhost',
      'mail_dir_base' => '/mail',
      'backup_dir' => '/root/deletetmp',
      'quota_user'  => 'quota1gb',
      'encrypt' => 'cleartext'
    }
    open(config_file, 'w') do |f|
      f.write config.to_yaml
    end
    File.chmod(0600, config_file)
  end
  def config_file
    File.expand_path(CONFIG_FILE, ENV['HOME'])
  end
  def add_domain(domain, password, user=nil)
    begin
      unless File.exist?(@config['apache_conf_file'])
        FileUtils.touch(@config['apache_conf_file'])
      end
      if include_apache_domain?(domain)
        raise "#{domain} is already registered in the apache config file."
      end

      user = user || domain
      add_unix_user(user, password)
      add_apache_domain(domain, user)
      add_mail_domain(domain, password)
    rescue => error
      exit_with_error(error)
    end
  end
  def delete_domain(domain, user=nil)
    begin
      user = user || domain
      backup_domain_data(domain, user)
      delete_domain_data(domain, user)

      res = apache_test
      if res
        puts "Apache test is OK!"
        exec("apachectl graceful")
      end
    rescue => error
      exit_with_error(error)
    end
  end

  private

  def exit_with_error(error)
    puts "Error: #{error.message}"
    puts "Exit"
    exit
  end

  def delete_domain_data(domain, user)
    delete_unix_user(user)
    delete_domain_http_conf(domain)
    delete_mail_data(domain)
  end
  def delete_domain_http_conf(domain)
    unless include_apache_domain?(domain)
      raise "#{domain} is not registered in the apache config file."
    end
    backup_conf= backup_apache_conf

    flag = false
    File.open(@config['apache_conf_file'], "w"){|wf|
      File.open(backup_conf){|f|
        f.each{|line|
          if line =~ /# #{domain} :/
            flag = true
          end
          if flag && line =~ /<\/VirtualHost>/
            flag = false
            next
          end
          wf.write line unless flag
        }
      }
    }
  end
  def backup_domain_data(domain, user)
    backup_web_data(domain, user)
    backup_mail_data(domain)
  end
  def backup_web_data(domain, user)
    output_value("Home", home_dir(user))
    output_value("Domain", domain)
    output_value("User", user)
    file = "#{domain}_web.tgz"
    tar_backup(file, home_dir(user))
  end
  def backup_mail_data(domain)
    backup_file = File.join(@config['backup_dir'], domain+'_mail.txt')
    exec("postfix_admin show #{domain} > #{backup_file}")
    file = "#{domain}_mail.tgz"
    tar_backup(file, mail_dir(domain))
  end
  def home_dir(user)
    File.join(@config['home_dir_base'], user)
  end
  def mail_dir(domain)
    File.join(@config['mail_dir_base'], domain)
  end
  def tar_backup(file, dir)
    unless File.exist?(dir)
      print "Can not find dir: #{dir}\n"
      return
    end
    basename = File.basename(dir)
    dirname  = File.dirname(dir)
    tar_file = File.join(@config['backup_dir'], file)
    res = exec("tar zcf #{tar_file} -C #{dirname} #{basename}")
    unless res
      raise("Tar command was failure")
    end
  end
  def delete_dir(dir)
    FileUtils.rm_rf(dir)
  end
  def add_unix_user(user, password)
    exec("useradd #{user} -m -d #{home_dir(user)} -s /sbin/nologin")
    exec("echo #{user}:#{password} | /usr/sbin/chpasswd")
    if @config['quota_user']
      exec("edquota -p #{@config['quota_user']} #{user}")
    end
    FileUtils.chmod(0711, home_dir(user))
  end
  def delete_unix_user(user)
    exec("userdel -r #{user}")
  end
  def delete_mail_data(domain)
    exec("postfix_admin delete_domain #{domain}")
    delete_dir(mail_dir(domain))
  end
  def add_apache_domain(domain, user)
    backup_apache_conf
    open(@config['apache_conf_file'], 'a') do |f|
      f.write(vhost_text(domain, user))
    end

    res = exec("apachectl -t")
    if res
      res_restart = exec("apachectl graceful")
      unless res_restart
        raise("Apache restart was failure.")
      end
    else
      raise("Apachec config test was failure.")
    end
  end
  def add_mail_domain(domain, password)
    set_password =
      if @crypt
        md5_crypt(password)
      else
        password
      end
    exec("postfix_admin add_domain #{domain}")
    exec("postfix_admin add_admin admin@#{domain} '#{set_password}'")
    exec("postfix_admin add_admin_domain admin@#{domain} #{domain}")
  end
  def md5_crypt(str)
    salt_set = ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a + ['.', '/']
    salt = '$1$'+salt_set.sample(8).join+'$'
    str.crypt(salt)
  end
  def vhost_text(domain, user)
    <<"EOS"

# #{domain} : #{date_time_str} by vhost_admin
<VirtualHost *:80>
    ServerAdmin postmaster@#{domain}
    ServerName www.#{domain}
    DocumentRoot #{home_dir(user)}/public_html
    ServerAlias #{domain}
    SuexecUserGroup #{user} #{user}
</VirtualHost>
EOS
  end
  # ServerName www.example.com
  def include_apache_domain?(domain)
    open(@config['apache_conf_file']) do |f|
      f.grep(/ServerName\s+www\.#{domain}/).size != 0
    end
  end
  def backup_apache_conf
    backup_conf = backup_apache_conf_file
    if File.exist?(@config['apache_conf_file'])
      FileUtils.copy(@config['apache_conf_file'], backup_apache_conf_file)
    end
    backup_conf
  end
  def backup_apache_conf_file
    @config['apache_conf_file'] + backup_suffix
  end
  def date_time_str
    DateTime.now.strftime("%Y-%m-%d %H:%M:%S")
  end
  def backup_suffix
    DateTime.now.strftime(".%Y%m%d%H%M%S")
  end
  def exec(cmd, debug=false)
    if debug
      output_value("Command(test run)",cmd)
      true
    else
      output_value("Command",cmd)
      system(cmd)
    end
  end
  def output_value(key, value)
    print "#{key}\t: #{value}\n"
  end
  def apache_test
    exec("apachectl -t")
  end
end
