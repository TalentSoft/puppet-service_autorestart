# class to provide service recovery for windows
class Puppet::Provider::ServiceRecovery::ServiceRecovery
  def initialize
    @regex_reset_period = Regexp.new(%r{\s*RESET_PERIOD \(in seconds\)    : (.*)\s*})
    @regex_reboot_message = Regexp.new(%r{\s*REBOOT_MESSAGE               : (.*)\s*})
    @regex_command_line = Regexp.new(%r{\s*COMMAND_LINE                 : (.*)\s*})
    @regex_restart = Regexp.new(%r{.*RESTART -- Delay = (\d+) milliseconds.\s*})
    @regex_run_process = Regexp.new(%r{.*RUN PROCESS -- Delay = (\d+) milliseconds.\s*})
    @regex_reboot = Regexp.new(%r{.*REBOOT -- Delay = (\d+) milliseconds.\s*})
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
      # is = change.key?(:is) ? change[:is] : service_recovery_instance(context, name)
      is = service_recovery_instance(context, name)
      should = change[:should]
      next unless should

      context.info("is=#{is} should=#{should}")

      context.updating(name) do
        arguments = []
        reset_changed = false
        failure_actions_changed = false
        if should[:reset_period] && (is[:reset_period] != should[:reset_period])
          context.attribute_changed(name,
                                    'reset_period',
                                    is[:reset_period],
                                    should[:reset_period])
          reset_changed = true
        end
        if should[:reboot_message] && (is[:reboot_message] != should[:reboot_message])
          context.attribute_changed(name,
                                    'reboot_message',
                                    is[:reboot_message],
                                    should[:reboot_message])
          arguments << "reboot=\"#{should[:reboot_message]}\""
        end
        if should[:command] && (is[:command] != should[:command])
          context.attribute_changed(name,
                                    'command',
                                    is[:command],
                                    should[:command])
          arguments << "command=\"#{should[:command]}\""
        end
        # if either of these attributes change, we need to specify both on CLI
        if should[:failure_actions] && (is[:failure_actions] != should[:failure_actions])
          context.attribute_changed(name,
                                    'failure_actions',
                                    is[:failure_actions],
                                    should[:failure_actions])
          failure_actions_changed = true
        end

        # sc.exe requires that both 'actions' and 'reset' be sent at the same
        # time, so if we change one we need to send both on the CLI
        if reset_changed || failure_actions_changed
          # reset arg
          arguments << "reset=#{should[:reset_period]}"

          # actions arg
          actions_arg = 'actions='
          should[:failure_actions].each do |value|
            context.info("failure value=#{value} value_class=#{value.class.name}")
            # note: hash keys are NOT symbolized
            action = case value['action']
                     when 'noop'
                       ''
                     when 'restart'
                       'restart'
                     when 'reboot'
                       'reboot'
                     when 'run_command'
                       'run'
                     end
            delay = value['delay']
            context.info("action=#{action} delay=#{delay}")
            actions_arg += "#{action}/#{delay}/"
          end
          context.info("actions_arg=#{actions_arg}")
          arguments << actions_arg
        end

        # only report changes if noop
        if noop
          context.info("service_recover[#{name}] would have run: sc.exe failure #{name} #{arguments.join(' ')}")
        else
          sc(['failure', name] + arguments)
        end
      end
    end
  end

  #######################
  # private method
  def sc(*args)
    unless @sc
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
      if (match = line.match(%r{SERVICE_NAME: (.*)\s*}))
        service_name = match.captures[0]
        memo << service_name.strip
      end
    end
  end

  def service_recovery_instance(context, service)
    # ask sc about failure/recovery information for this service
    qfailure = sc('qfailure', service)

    # TODO: document the idempotency of specifying "noop" for failure actions
    #   - FYI it will result in loss of idempotency because the sc out put doesn't
    #     give us a "noop" placeholder
    recovery = {
      name: service,
    }
    qfailure.lines.each_with_object(recovery) do |line, memo|
      if !memo.key?(:reset_period) && (match = @regex_reset_period.match(line))
        context.info("line = '#{line}' matched reset_period")
        memo[:reset_period] = match.captures[0].to_i
      elsif !memo.key?(:reboot_message) && (match = @regex_reboot_message.match(line))
        context.info("line = '#{line}' matched reboot message")
        memo[:reboot_message] = match.captures[0]
      elsif !memo.key?(:command) && (match = @regex_command_line.match(line))
        context.info("line = '#{line}' matched command")
        memo[:command] = match.captures[0]
      elsif (match = @regex_restart.match(line))
        context.info("line = '#{line}' matched restart")
        delay_ms = match.captures[0].to_i
        memo[:failure_actions] = [] unless memo.key?(:failure_actions)
        # note: hash keys are NOT symbolized
        memo[:failure_actions] << {
          'action' => 'restart',
          'delay' => delay_ms,
        }
      elsif (match = @regex_run_process.match(line))
        context.info("line = '#{line}' matched run process")
        delay_ms = match.captures[0].to_i
        memo[:failure_actions] = [] unless memo.key?(:failure_actions)
        # note: hash keys are NOT symbolized
        memo[:failure_actions] << {
          'action' => 'run_command',
          'delay' => delay_ms,
        }
      elsif (match = @regex_reboot.match(line))
        context.info("line = '#{line}' matched reboot")
        delay_ms = match.captures[0].to_i
        memo[:failure_actions] = [] unless memo.key?(:failure_actions)
        # note: hash keys are NOT symbolized
        memo[:failure_actions] << {
          'action' => 'reboot',
          'delay' => delay_ms,
        }
      else
        context.info("line = '#{line}' didn't match anything")
      end
    end
  end
end
