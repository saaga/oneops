class SupportController < ReportsController
  skip_before_filter :check_reset_password, :check_eula, :check_username, :check_organization, :set_active_resource_headers
  before_filter :clear_active_resource_headers
  before_filter :authorize

  def show
  end

  def announcements
    @announcements = MiscDoc.announcements
    if request.put?
      if @announcements.update_attribute(:document, params[:document])
        flash[:notice] = 'Updated announcements.'
      else
        flash[:error] = "Could not update announcements: #{@announcements.errors.full_messages.join('; ')}"
      end
    else
      @announcements.document ||= {:notice => nil, :critical => nil}
    end

    respond_to do |format|
      format.html
      format.js
      format.json {render :json => @announcements}
    end
  end

  def compute_report
  end

  def organizations
    page_size = (params[:size].presence || (request.format.json? ? 100 : 9999999)).to_i
    offset    = (params[:offset].presence || 0).to_i
    sort      = params[:sort].presence || 'organizations.name ASC'
    name      = params[:name]
    scope     = Organization

    scope = scope.where('organizations.name ILIKE ?', "%#{name}%") if name.present?

    total = scope.count

    if total > 0
      scope = scope.limit(page_size).offset(offset).order(sort)
      @organizations = scope.select("organizations.*, 0 as team_count, 0 as user_count, 0 as group_count, 0 as admin_count, '' as owner").all

      if @organizations.present?
        org_owners = Cms::Ci.list(@organizations.map(&:cms_id)).to_map_with_value {|o| [o['ciId'], o['ciAttributes']['owner']]}

        counts = Organization.
          select('organizations.id').
          select('count(distinct teams_users.user_id) as user_count').
          select('count(distinct teams.id) as team_count').
          select('count(distinct groups_teams.group_id) as group_count').
          from("(#{scope.to_sql}) AS organizations").
          joins(:teams).
          joins('LEFT OUTER JOIN teams_users ON teams.id = teams_users.team_id').
          joins('LEFT OUTER JOIN groups_teams ON teams.id = groups_teams.team_id').
          group('organizations.id').all.to_map(&:id)


        admin_counts = Organization.
          select('organizations.id, count(teams_users.user_id) as admin_count').
          from("(#{scope.to_sql}) AS organizations").
          joins(:admin_users).
          group('organizations.id').all.to_map(&:id)

        @organizations.each do |o|
          count         = counts[o.id]
          o.owner       = org_owners[o.cms_id]
          o.user_count  = count.user_count
          o.team_count  = count.team_count
          o.group_count = count.group_count
          o.admin_count = admin_counts[o.id].admin_count
        end
      end
    else
      @organizations = []
    end

    respond_to do |format|
      format.html

      format.js

      format.json do
        add_pagination_response_headers(total, @organizations.size, offset)
        render :json => @organizations.to_json(:methods => :owner)
      end

      format.any do
        add_pagination_response_headers(total, @organizations.size, offset)
        keys = %w(id name full_name created_at owner team_count user_count group_count admin_count)
        delimiter = params[:delimiter].presence || ','
        csv = keys.join(delimiter) << "\n"
        @organizations.each do |o|
          csv << keys.inject([]) {|a, k| a << o.attributes[k]}.join(delimiter) << "\n"
        end
        render :text => csv
      end
    end
  end

  # delimiter
  def organization
    org_name   = params[:name]
    @organization = Organization.where(:name => org_name).first
    ok = @organization.present?
    if ok
      org_name       = @organization.name
      ns_path        = organization_ns_path(org_name)
      assembly_count = Cms::Ci.all(:params => {:nsPath      => ns_path,
                                               :ciClassName => 'account.Assembly'}).size
      cloud_count    = Cms::Ci.all(:params => {:nsPath      => clouds_ns_path(org_name),
                                               :ciClassName => 'account.Cloud'}).size
      instance_count = Cms::Relation.count(:nsPath            => ns_path,
                                           :recursive         => true,
                                           :relationShortName => 'DeployedTo',
                                           :direction         => 'to',
                                           :groupBy           => 'ciId').values.sum
      admins = @organization.teams.where(:name => Team::ADMINS).first
      @counts = {'admin'    => admins ? admins.users.size : 0,
                 'team'     => @organization.teams.size,
                 'cloud'    => cloud_count,
                 'asembly'  => assembly_count,
                 'instance' => instance_count}

      if request.delete?
        if instance_count > 0
          ok = false
          message = "Cannot delete organization with deployed instances (#{instance_count})."
          flash[:error] = message
          @organization.errors.add(:base, message)
        end

        if ok
          confirmation_errors = []
          @counts.each_pair {|name, count| confirmation_errors << name unless params["#{name}_count"].to_i == count}
          if confirmation_errors.present?
            ok = false
            message = "Incorrect confirmation counts for: #{confirmation_errors.join(', ')}."
            flash[:error] = message
            @organization.errors.add(:base, message)
          end
        end

        if ok
          Organization.transaction do
            ci = @organization.ci
            ok = @organization.destroy
            if ok
              ok = execute(ci, :destroy)
              flash[:alert] = "Organization #{org_name} and all its data are PERMANENTLY deleted." if ok
            else
              raise ActiveRecord::Rollback, 'Failed to delete organization in CMS.'
            end
          end
        end
      end
    else
      flash[:error] = "Organization '#{org_name}' not found." unless @organization
    end

    respond_to do |format|
      format.js

      format.json do
        if ok
          render :json => {:organization => @organization, :counts => @counts}, :status => :ok
        elsif @organization
          render :json => {:errors => @organization.errors.full_messages}, :status => :unprocessable_entity
        else
          render :json => {:errors => ['not found']}, :status => :not_found
        end
      end
    end
  end

  def users
    username = params[:login]
    users = []
    if username.present?
      login = "%#{username}%"
      users = User.where('username LIKE ? OR name LIKE ?', login, login).limit(20).map {|u| "#{u.username} #{u.name if u.name.present?}"}
    else
      last_sign_in = params[:active_since]
      users = User.select('username, email, current_sign_in_at').where('current_sign_in_at >= ?', last_sign_in).all if last_sign_in.present?
    end

    respond_to do |format|
      format.csv {render :text => users.map {|u| "#{u.username},#{u.email},#{u.current_sign_in_at}"}.join("\n")}
      format.any {render :json => users}
    end

  end

  def user
    user_id = params[:id]
    if user_id.present?
      @user = User.where((user_id =~ /\D/ ? :username : :id) => user_id).first
      if @user
        @groups = @user.groups.select('groups.*, group_members.admin').order(:name).all
        team_ids = @user.teams.pluck('teams.organization_id') + @user.teams_via_groups.pluck('teams.organization_id').uniq
        @teams = Team.where('teams.id IN (?)', team_ids).
          includes(:organization).
          order('organizations.name, teams.name').all.
          group_by {|t| t.organization}.inject([]) do |a, (org, teams)|
          a << {:id => org.id, :organization => org.name, :items => teams}
        end
      end
    end

    respond_to do |format|
      format.html
      format.js
      format.json {render_json_ci_response(@user.present?, @user)}
    end
  end

  def cost
    super
  end

  def deployment_to_all_primary_check
    ok = true
    doc = MiscDoc.deployment_to_all_primary_check
    doc_hash = doc.document
    if request.put?
      doc_hash.clear if params[:clear] || params[:delete_all]
      delete = params[:delete]
      (delete.is_a?(Array) ? delete : [delete]).each {|ns| doc_hash.delete(ns)} if delete.present?
      add = params[:add]
      (add.is_a?(Array) ? add : [add]).each {|ns| doc_hash[ns] = true} if add.present?
      ok = doc.save
    end
    render_json_ci_response(ok, doc)
  end

  def obsolete_users
    ldap          = Settings.authentication == 'ldap' && Devise::LdapAdapter.ldap_connect(nil)
    obsolte_users = []
    total         = 0
    User.select('id, username, email, name, created_at, current_sign_in_at, sign_in_count').
      where('current_sign_in_at < ?', params[:since]).
      find_in_batches(:batch_size => (params[:batch_size] || 20).to_i) do |batch|
      total += batch.size
      if ldap
        entries = ldap.search_for_logins(batch.map(&:username))
        batch.each do |u|
          unless entries[u.username]
            obsolte_users << u
          end
        end
      end
    end

    if request.delete?
      if params[:count].to_i == obsolte_users.size
        deleted_users = []
        not_deleted_users = []
        obsolte_users.each do |u|
          next unless u[:username] == 'foobar3' || u[:username] == 'foobar9'
          if u.destroy
            deleted_users << u
          else
            u[:errors] = user.errors.full_messages
            not_deleted_users << u
          end
        end
        render :json => {:total => total, :deleted => deleted_users.size, :obsolete => not_deleted_users.size, :deleted_users => deleted_users, :obsolete_users => not_deleted_users}.to_json
      else
        render :json => {:errors => ['Provide correct obsolete user count to confirm delete request']}, :status => :unprocessable_entity
      end
    else
      render :json => {:total => total, :obsolete => obsolte_users.size, :obsolete_users => obsolte_users}.to_json
    end

  end


  protected

  def is_admin?
    return true
  end

  def search_ns_path
    '/'
  end

  def compute_report_data
    old_timeout = Cms::Base.timeout
    Cms::Base.timeout = 180 if Settings.cms_http_timeout < 180
    super
  ensure
    Cms::Base.timeout = old_timeout
  end

  def compute_report_graph_data
    assemblies = Cms::Ci.all(:params => {:nsPath      => '/',
                                         :ciClassName => 'account.Assembly',
                                         :recursive   => true}).inject({}) do |h, a|
      h[a.ciName] = a
      h
    end

    quota_map, cloud_compute_tenant_map = get_quota_map('/')

    bom_computes = Cms::Ci.all(:params => {:nsPath      => '/',
                                           :ciClassName => 'Compute',
                                           :recursive   => true}).inject({}) do |m, c|
      m[c.ciId] = c
      m
    end

    data = Cms::Relation.all(:params => {:nsPath            => '/',
                                         :relationShortName => 'DeployedTo',
                                         :fromClassName     => 'Compute',
                                         :recursive         => true}).inject({}) do |m, r|
      bom_compute = bom_computes[r.fromCiId]
      foo, org, assembly, env, area, platform = bom_compute.nsPath.split('/')
      compute_service_info = cloud_compute_tenant_map[r.toCiId]
      if compute_service_info
        compute = compute_service_info[:compute]
        org_tenant = "#{org}/#{compute_service_info ? compute_service_info[:tenant] : ''}"
      else
        compute = "cloud_#{r.toCiId}"
        org_tenant = org
      end
      m[compute] ||= {}
      m[compute][org_tenant] ||= {}
      m[compute][org_tenant][CONSUMED_LABEL] ||= {}
      m[compute][org_tenant][CONSUMED_LABEL][assembly] ||= LeafNode.new(:metrics => empty_compute_metrics,
                                                                        :url     => assembly.present? && env.present? ? assembly_operations_environment_url(:org_name => org, :assembly_id => assembly, :id => env) : assembly_path(:org_name => org, :id => assembly),
                                                                        :info    => {:owner => assemblies[assembly].ciAttributes.owner})
      aggregate_compute_metrics(m[compute][org_tenant][CONSUMED_LABEL][assembly][:metrics], bom_compute)
      m
    end

    graph_data = graph_node('ALL', data)

    compute_nodes = graph_data[:children]
    quota_map.each_pair do |compute_org_tenant, quota|
      split = compute_org_tenant.split('/')
      compute = split.first
      compute_node = compute_nodes.find {|node| node[:name] == compute}
      unless compute_node
        compute_node = {:name => compute, :children => [], :level => 3, :metrics => empty_compute_metrics, :id => random_node_id}
        compute_nodes << compute_node
      end

      org_tenant = split[1..-1].join('/')
      org_tenant_nodes = compute_node[:children]
      org_tenant_node = org_tenant_nodes.find {|node| node[:name] == org_tenant}
      unless org_tenant_node
        org_tenant_node = {:name => org_tenant, :children => [], :level => 2, :metrics => empty_compute_metrics, :id => random_node_id}
        org_tenant_nodes << org_tenant_node
      end
      insert_quota_data(org_tenant_node, quota)
      aggregate_graph_node(org_tenant_node)
      aggregate_graph_node(compute_node)
    end

    aggregate_graph_node(graph_data)

    scope = ['Service', 'Org/Tenant', 'Allocation', {'Assembly' => ['name', 'owner']}]

    return graph_data, scope
  end


  private

  def authorize
    action = action_name
    if action == 'show'
      perm = support_permissions.keys.first
    elsif action.start_with?('organization')
      perm = 'organization'
    elsif action.start_with?('user')
      perm = 'user'
    elsif action.start_with?('compute')
      perm = 'compute_report'
    elsif action.include?('announcements')
      perm = 'announcement'
    else
      perm = action
    end

    unauthorized unless has_support_permission?(perm)
  end

  def add_pagination_headers

  end
end
