require "log4r"

require 'vagrant/util/retryable'

require 'vagrant-brightbox/util/timer'

module VagrantPlugins
  module Brightbox
    module Action
      # This creates the Brightbox Server
      class CreateServer
        include Vagrant::Util::Retryable

        def initialize(app, env)
          @app    = app
          @logger = Log4r::Logger.new("vagrant_brightbox::action::create_server")
        end

        def call(env)
          # Initialize metrics if they haven't been
          env[:metrics] ||= {}

          # Get the region we're going to booting up in
          region = env[:machine].provider_config.region

          # Get the configs
          region_config    = env[:machine].provider_config.get_region_config(region)
          image_id         = region_config.image_id
          zone             = region_config.zone
          server_name      = region_config.server_name
          server_type      = region_config.server_type
          server_groups    = region_config.server_groups
          user_data        = region_config.user_data

          zone_id  = normalise_id(
            lambda { env[:brightbox_compute].zones },
            zone,
            /^zon-/)
          server_type_id = normalise_id(
            lambda { env[:brightbox_compute].flavors },
            server_type,
            /^typ-/)

          # Launch!
          env[:ui].info(I18n.t("vagrant_brightbox.launching_server"))
          env[:ui].info(I18n.t("vagrant_brightbox.supplied_user_data")) if user_data
          env[:ui].info(" -- Type: #{server_type}") if server_type
          env[:ui].info(" -- Image: #{image_id}") if image_id
          env[:ui].info(" -- Region: #{region}")
          env[:ui].info(" -- Name: #{server_name}") if server_name
          env[:ui].info(" -- Zone: #{zone}") if zone
          env[:ui].info(" -- Server Groups: #{server_groups.inspect}") if !server_groups.empty?
          @logger.info(" -- Zone ID: #{zone_id}") if zone_id
          @logger.info(" -- Type ID: #{server_type_id}") if server_type_id

          begin
            options = {
              :image_id => image_id,
              :name => server_name,
              :flavor_id => server_type_id,
              :user_data => user_data,
              :zone_id => zone_id
            }

            options[:server_groups] = server_groups unless server_groups.empty?

            server = env[:brightbox_compute].servers.create(options)
          rescue Excon::Errors::HTTPStatusError => e
            raise Errors::FogError, :message => e.response
          end

          # Immediately save the ID since it is created at this point.
          env[:machine].id = server.id

          # Wait for the server to build
          env[:metrics]["server_build_time"] = Util::Timer.time do
            tries = region_config.server_build_timeout / 2
            env[:ui].info(I18n.t("vagrant_brightbox.waiting_for_build"))
            begin
              retryable(:on => Fog::Errors::TimeoutError, :tries => tries) do
                # If we're interrupted don't worry about waiting
                next if env[:interrupted]

                # Wait for the server to be ready
                server.wait_for(2) { ready? }
              end
            rescue Fog::Errors::TimeoutError
              # Delete the server
              terminate(env)

              # Notify the user
              raise Errors::ServerBuildTimeout, timeout: region_config.server_build_timeout
            end
          end

          @logger.info("Time for server to build: #{env[:metrics]["server_build_time"]}")

          if !env[:interrupted]
            @app.call(env)
            env[:metrics]["instance_ssh_time"] = Util::Timer.time do
              # Wait for SSH to be ready.
              env[:ui].info(I18n.t("vagrant_brightbox.waiting_for_ssh"))
              while true
                # If we're interrupted then just back out
                break if env[:interrupted]
                break if ready?(env[:machine])
                sleep 2
              end
            end

            @logger.info("Time for SSH ready: #{env[:metrics]["instance_ssh_time"]}")

            # Ready and booted!
            env[:ui].info(I18n.t("vagrant_brightbox.ready"))
          end

          # Terminate the instance if we were interrupted
          terminate(env) if env[:interrupted]
        end

        # Check if machine is ready, trapping only non-fatal errors
        def ready?(machine)
          @logger.info("Checking if SSH is ready or is permanently broken...")
          @logger.info("Connecting as '#{machine.ssh_info[:username]}'") if machine.ssh_info[:username]
          # Yes this is cheating.
          machine.communicate.send(:connect)
          @logger.info("SSH is ready")
          true
          # Fatal errors
        rescue Vagrant::Errors::SSHAuthenticationFailed
          raise
          # Transient errors
        rescue Vagrant::Errors::VagrantError => e
          @logger.info("SSH not up: #{e.inspect}")
          return false
        end

        def recover(env)
          return if env["vagrant.error"].is_a?(Vagrant::Errors::VagrantError)

          if env[:machine].provider.state.id != :not_created
            # Undo the import
            terminate(env)
          end
        end

        def terminate(env)
          destroy_env = env.dup
          destroy_env.delete(:interrupted)
          destroy_env[:config_validate] = false
          destroy_env[:force_confirm_destroy] = true
          env[:action_runner].run(Action.action_destroy, destroy_env)
        end

        def normalise_id(collection, element, pattern)
          @logger.info("Normalising element #{element.inspect}")
          @logger.info("Against pattern #{pattern.inspect}")
          case element
          when pattern, nil
            element
          else
            result = collection.call.find { |f| f.handle == element }
            if result
              result.id
            else
              element
            end
          end
        end
      end
    end
  end
end
