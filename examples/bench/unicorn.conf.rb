# frozen_string_literal: true

require "message_bus"
after_fork do |_server, _worker|
  MessageBus.after_fork
end
