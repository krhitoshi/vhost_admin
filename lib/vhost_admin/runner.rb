require 'vhost_admin/base'

class VhostAdmin::Runner < Thor
  desc "add_domain", "add a domain"
  method_options :crypt => :boolean
  def add_domain(domain, password, user=nil)
    admin = VhostAdmin::Base.new(options)
    admin.add_domain(domain, password, user)
  end

  desc "delete_domain", "delete a domain"
  def delete_domain(domain, user=nil)
    admin = VhostAdmin::Base.new
    admin.delete_domain(domain, user)
  end
end
