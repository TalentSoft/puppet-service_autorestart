# class to provide service recovery for windows
class Puppet::Provider::ServiceRecovery::ServiceRecovery
  def initialize
    @regex_service_name = Regexp.new(%r{SERVICE_NAME: (.*)\s*})
    @regex_reset_period = Regexp.new(%r{\s*RESET_PERIOD \(.*\)\s*: (.*)\s*})
    @regex_reboot_message = Regexp.new(%r{\s*REBOOT_MESSAGE\s*: (.*)\s*})
    @regex_command_line = Regexp.new(%r{\s*COMMAND_LINE\s*: (.*)\s*})
    @regex_restart = Regexp.new(%r{.*RESTART -- .* = (\d+) .*\s*})
    @regex_run_process = Regexp.new(%r{.*RUN PROCESS -- .* = (\d+) .*\s*})
    @regex_reboot = Regexp.new(%r{.*REBOOT -- .* = (\d+) .*\s*})
    # maps failure_action 'action's to the 'action' names in the sc.exe command
    @failure_action_sc_map = {
      'noop' => '',
      'restart' => 'restart',
      'reboot' => 'reboot',
      'run_command' => 'run',
    }
  end

  #######################
  # public methods inherited from Resource API
  def get(context, names = nil)
    # because we specified the simple_get_filter feature in our type definition
    # we will now get passed a list of names (or nil) to retrieve
    # this allows us to just get the instances declared in Puppet DSL instead of
    # getting _all_ instances (slow)
    #
    # names might be nil, so check for that
    return [] unless names

    # for each service, ask sc for information on its service recovery (aka failure)
    # configuration
    names.map { |service_name| service_recovery_instance(context, service_name) }
  end

  # make bulk changes to the resources
  def set(context, changes, noop: false)
    changes.each do |name, change|
      # changes[:is] contains the "cached" state of the resource returned by get()
      # changes[:should] contains the desired state declared in the Puppet DSL
      #
      # just in case change[:is] doesn't contain a cached instance, get the instance now
      is = change.key?(:is) ? change[:is] : service_recovery_instance(context, name)
      should = change[:should]

      # should can be 'nil' if it needs to be deleted
      # we don't support deleting/purging service control options, so skip this chnage
      next unless should

      # log that we're updating
      context.updating(name) do
        arguments = []
        reset_or_failure_actions_changed = false

        # check attributes for changes, we have this in a function so that we can
        # log the attributes that changed (DRY)
        if attribute_changed(context, name, :reset_period, is, should) ||
           attribute_changed(context, name, :failure_actions, is, should)
          reset_or_failure_actions_changed = true
        end
        if attribute_changed(context, name, :reboot_message, is, should)
          arguments << "reboot=\"#{should[:reboot_message]}\""
        end
        if attribute_changed(context, name, :command, is, should)
          arguments << "command=\"#{should[:command]}\""
        end

        # sc.exe requires that both 'actions' and 'reset' be sent at the same
        # time, so if we change one we need to send both on the CLI
        if reset_or_failure_actions_changed
          # reset arg
          arguments << "reset=#{should[:reset_period]}"

          # actions arg
          actions_arg = 'actions='
          should[:failure_actions].each do |value|
            # note: hash keys are NOT symbolized
            action = @failure_action_sc_map[value['action']]
            delay = value['delay']
            actions_arg += "#{action}/#{delay}/"
          end
          arguments << actions_arg
        end

        # only report changes if noop
        if noop
          context.info("service_recovery[#{name}] would have run: sc.exe failure #{name} #{arguments.join(' ')}")
        else
          # run the "bulk" command to set all of the things that changed for the recovery
          # options all at the same time
          sc(['failure', name] + arguments)
        end
      end
    end
  end

  #######################
  # private method
  def sc(*args)
    unless @sc
      # use Puppet::Provider::Command here because we're running a "native" command
      # this is MUCH faster than launching powershell, even with pwshlib
      @sc = Puppet::Provider::Command.new('sc',
                                          'sc.exe',
                                          Puppet::Util,
                                          Puppet::Util::Execution,
                                          failonfail: true,
                                          combine: true,
                                          custom_environment: {})
    end
    @sc.execute(*args)
  end

  def services_list(_context)
    return @services_list if @services_list
    query = sc('query')
    @services_list = query.lines.each_with_object([]) do |line, memo|
      # skip lines that aren't names of services
      # format:
      #  SERVICE_NAME: <service_name>\r\n
      if (match = line.match(@regex_service_name))
        service_name = match.captures[0]
        memo << service_name.strip
      end
    end
  end

  def service_recovery_instance(_context, service)
    # ask sc about failure/recovery information for this service
    qfailure = sc('qfailure', service)

    # TODO: document the idempotency of specifying "noop" for failure actions
    #   - FYI it will result in loss of idempotency because the sc out put doesn't
    #     give us a "noop" placeholder
    recovery = {
      name: service,
    }
    # parse each line, by matching to regexes that extract data from the command output
    qfailure.lines.each_with_object(recovery) do |line, memo|
      if !memo.key?(:reset_period) && (match = @regex_reset_period.match(line))
        memo[:reset_period] = match.captures[0].to_i
      elsif !memo.key?(:reboot_message) && (match = @regex_reboot_message.match(line))
        memo[:reboot_message] = match.captures[0]
      elsif !memo.key?(:command) && (match = @regex_command_line.match(line))
        memo[:command] = match.captures[0]
      elsif (match = @regex_restart.match(line))
        add_failure_action(memo, 'restart', match.captures[0].to_i)
      elsif (match = @regex_run_process.match(line))
        add_failure_action(memo, 'run_command', match.captures[0].to_i)
      elsif (match = @regex_reboot.match(line))
        add_failure_action(memo, 'reboot', match.captures[0].to_i)
      end
    end
  end

  def add_failure_action(memo, action, delay_ms)
    memo[:failure_actions] = [] unless memo.key?(:failure_actions)
    # note: hash keys are NOT symbolized
    memo[:failure_actions] << {
      'action' => action,
      'delay' => delay_ms,
    }
  end

  def attribute_changed(context, name, prop, is, should)
    changed = should[prop] && (is[prop] != should[prop])
    context.attribute_changed(name, prop.to_s, is[prop], should[prop]) if changed
    changed
  end
end
