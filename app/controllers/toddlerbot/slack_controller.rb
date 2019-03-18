# frozen_string_literal: true

module Toddlerbot
  class SlackController < ActionController::API
    include SlackTokenVerify

    SLACK_TIMEOUT_SECONDS = 3.seconds

    def event_callback
      if params[:type] == "url_verification"
        render plain: params["challenge"]
      elsif params[:event][:type] == "message"
        handle_direct_message_event
        head :ok
      else
        head :bad_request
      end
    end

    def interactive_callback
      parsed_payload = JSON.parse(params[:payload])
      response = handler_from_callback_id(parsed_payload["callback_id"]).call(parsed_payload)
      if !response.nil?
        Timeout.timeout(SLACK_TIMEOUT_SECONDS) do
          render json: response
        end
      else
        head :ok
      end
    rescue Timeout::Error
      raise Timeout::Error, "Slack interactive callback timed out for #{parsed_payload['callback_id']}"
    end

    def slash_command_callback
      handler_class = params[:handler_class]
      handler_method = params[:handler_method]
      verify_handler_slash_permission(handler_class, handler_method)

      response = handler_class.camelize.constantize.method(handler_method).call(params)
      if !response.nil?
        Timeout.timeout(SLACK_TIMEOUT_SECONDS) do
          render json: response
        end
      else
        head :ok
      end
    rescue Timeout::Error
      raise Timeout::Error, "Slack slash command callback timed out for command #{params[:command]}"
    end

    private

    def handle_direct_message_event
      if handler = Toddlerbot.configuration.custom_event_subtype_handlers[params[:event][:subtype]]
        handler.handle_event(params[:slack])
        head :ok
        return
      end

      return if params[:event][:subtype] == "bot_message" || params[:event].key?(:bot_id) || params[:event][:hidden]

      command = params[:event][:text]
      Toddlerbot.configuration.handlers.call_command(command, params[:slack])
    rescue RuntimeError => e
      raise e unless e.message == "Component not found for a command message"
    end

    def handler_from_callback_id(callback_id)
      class_name, method_name = callback_id.split('#')
      class_name.camelize.constantize.method(method_name)
    end

    def verify_handler_slash_permission(handler_class, handler_method)
      handler = handler_class.camelize.constantize
      raise Toddlerbot::Exceptions::MissingSlashPermission, "#{handler_class}##{handler_method} is missing slash permission" unless
        handler < BaseHandler && handler.allowed_slash_methods.include?(handler_method.to_sym)
    end
  end
end
