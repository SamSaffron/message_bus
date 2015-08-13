# coding: utf-8

require 'spec_helper'
require 'message_bus'
require 'rack/test'

describe MessageBus::Rack::Middleware do
  include Rack::Test::Methods

  before do
    bus = @bus = MessageBus::Instance.new
    @bus.long_polling_enabled = false

    builder = Rack::Builder.new {
      use FakeAsyncMiddleware, :message_bus => bus
      use MessageBus::Rack::Middleware, :message_bus => bus
      run lambda {|env| [500, {'Content-Type' => 'text/html'}, 'should not be called' ]}
    }

    @async_middleware = builder.to_app
    @message_bus_middleware = @async_middleware.app
  end

  after do |x|
    @message_bus_middleware.stop_listener
    @bus.reset!
    @bus.destroy
  end

  def app
    @async_middleware
  end

  shared_examples "long polling" do
    before do
      @bus.long_polling_enabled = true
    end

    it "should respond right away if dlp=t" do
      post "/message-bus/ABC?dlp=t", '/foo1' => 0
      @async_middleware.in_async?.should == false
      last_response.should be_ok
    end

    it "should respond right away to long polls that are polling on -1 with the last_id" do
      post "/message-bus/ABC", '/foo' => -1
      last_response.should be_ok
      parsed = JSON.parse(last_response.body)
      parsed.length.should == 1
      parsed[0]["channel"].should == "/__status"
      parsed[0]["data"]["/foo"].should == @bus.last_id("/foo")
    end

    it "should respond to long polls when data is available" do
      middleware = @async_middleware
      bus = @bus

      @bus.extra_response_headers_lookup do |env|
        {"FOO" => "BAR"}
      end

      Thread.new do
        wait_for(2000) {middleware.in_async?}
        bus.publish "/foo", "םוֹלשָׁ"
      end

      post "/message-bus/ABC", '/foo' => nil

      last_response.should be_ok
      parsed = JSON.parse(last_response.body)
      parsed.length.should == 1
      parsed[0]["data"].should == "םוֹלשָׁ"

      last_response.headers["FOO"].should == "BAR"
    end

    it "should timeout within its alloted slot" do
      begin
        @bus.long_polling_interval = 10
        s = Time.now.to_f * 1000
        post "/message-bus/ABC", '/foo' => nil
        (Time.now.to_f * 1000 - s).should < 30
      ensure
        @bus.long_polling_interval = 5000
      end
    end

    it "should support batch filtering" do
      bus = @bus
      async_middleware = @async_middleware

      bus.user_id_lookup do |env|
        1
      end

      bus.around_client_batch("/demo") do |message, user_ids, callback|
        begin
          Thread.current["test"] = user_ids
          callback.call
        ensure
          Thread.current["test"] = nil
        end
      end

      test = nil

      bus.client_filter("/demo") do |user_id, message|
        test = Thread.current["test"]
        message
      end

      client_id = "ABCD"

      id = bus.publish("/demo", "test")

      Thread.new do
        wait_for(2000) { async_middleware.in_async? }
        bus.publish "/demo", "test"
      end

      post "/message-bus/#{client_id}", {
        '/demo' => id
      }

      test.should == [1]
    end

    it "should support json post data" do
      header "Content-Type", "application/json"
      post "/message-bus/ABC", {'/foo' => -1}.to_json
      last_response.should be_ok
      parsed = JSON.parse(last_response.body)
      parsed.length.should == 1
      parsed[0]["channel"].should == "/__status"
      parsed[0]["data"]["/foo"].should == @bus.last_id("/foo")
    end
  end

  describe "thin async" do
    before do
      @async_middleware.simulate_thin_async
    end
    it_behaves_like "long polling"
  end

  describe "hijack" do
    before do
      @async_middleware.simulate_hijack
      @bus.rack_hijack_enabled = true
    end
    it_behaves_like "long polling"
  end

  describe "diagnostics" do

    it "should return a 403 if a user attempts to get at the _diagnostics path" do
      get "/message-bus/_diagnostics"
      last_response.status.should == 403
    end

    it "should get a 200 with html for an authorized user" do
      @bus.stub(:is_admin_lookup).and_return(lambda{|env| true })
      get "/message-bus/_diagnostics"
      last_response.status.should == 200
    end

    it "should get the script it asks for" do
      @bus.stub(:is_admin_lookup).and_return(lambda{|env| true })
      get "/message-bus/_diagnostics/assets/message-bus.js"
      last_response.status.should == 200
      last_response.content_type.should == "text/javascript;"
    end

  end

  describe "polling" do
    before do
      @bus.long_polling_enabled = false
    end

    it "should include access control headers" do
      @bus.extra_response_headers_lookup do |env|
        {"FOO" => "BAR"}
      end

      client_id = "ABCD"

      # client always keeps a list of channels with last message id they got on each
      post "/message-bus/#{client_id}", {
        '/foo' => nil,
        '/bar' => nil
      }

      last_response.headers["FOO"].should == "BAR"
    end

    it "should respond with a 200 to a subscribe" do
      client_id = "ABCD"

      # client always keeps a list of channels with last message id they got on each
      post "/message-bus/#{client_id}", {
        '/foo' => nil,
        '/bar' => nil
      }
      last_response.should be_ok
    end

    it "should correctly understand that -1 means stuff from now onwards" do

      @bus.publish('foo', 'bar')

      post "/message-bus/ABCD", {
        '/foo' => -1
      }
      last_response.should be_ok
      parsed = JSON.parse(last_response.body)
      parsed.length.should == 1
      parsed[0]["channel"].should == "/__status"
      parsed[0]["data"]["/foo"].should ==@bus.last_id("/foo")

    end

    it "should respond with the data if messages exist in the backlog" do
      id =@bus.last_id('/foo')

      @bus.publish("/foo", "barbs")
      @bus.publish("/foo", "borbs")

      client_id = "ABCD"
      post "/message-bus/#{client_id}", {
        '/foo' => id,
        '/bar' => nil
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 2
      parsed[0]["data"].should == "barbs"
      parsed[1]["data"].should == "borbs"
    end

    it "should have no cross talk" do

      seq = 0
      @bus.site_id_lookup do
        (seq+=1).to_s
      end

      # published on channel 1
      msg = @bus.publish("/foo", "test")

      # subscribed on channel 2
      post "/message-bus/ABCD", {
        '/foo' => (msg-1)
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 0

    end

    it "should have global cross talk" do

      seq = 0
      @bus.site_id_lookup do
        (seq+=1).to_s
      end

      msg = @bus.publish("/global/foo", "test")

      post "/message-bus/ABCD", {
        '/global/foo' => (msg-1)
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 1
    end

    it "should not get consumed messages" do
      @bus.publish("/foo", "barbs")
      id =@bus.last_id('/foo')

      client_id = "ABCD"
      post "/message-bus/#{client_id}", {
        '/foo' => id
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 0
    end

    it "should filter by user correctly" do
      id =@bus.publish("/foo", "test", user_ids: [1])
      @bus.user_id_lookup do |env|
        0
      end

      client_id = "ABCD"
      post "/message-bus/#{client_id}", {
        '/foo' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 0

      @bus.user_id_lookup do |env|
        1
      end

      post "/message-bus/#{client_id}", {
        '/foo' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 1
    end


    it "should filter by client_filter correctly" do
      id = @bus.publish("/filter", "test")
      uid = 0

      @bus.user_id_lookup do |env|
        uid
      end

      @bus.client_filter("/filter") do |user_id, message|
        if user_id == 0
          message = message.dup
          message.data += "_filter"
          message
        elsif user_id == 1
          message
        end
      end

      client_id = "ABCD"

      post "/message-bus/#{client_id}", {
        '/filter' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed[0]['data'].should == "test_filter"

      uid = 1

      post "/message-bus/#{client_id}", {
        '/filter' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 1
      parsed[0]["data"].should == "test"

      uid = 2

      post "/message-bus/#{client_id}", {
        '/filter' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 0
    end

    it "should filter by group correctly" do
      id =@bus.publish("/foo", "test", group_ids: [3,4,5])
      @bus.group_ids_lookup do |env|
        [0,1,2]
      end

      client_id = "ABCD"
      post "/message-bus/#{client_id}", {
        '/foo' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 0

      @bus.group_ids_lookup do |env|
        [1,7,4,100]
      end

      post "/message-bus/#{client_id}", {
        '/foo' => id - 1
      }

      parsed = JSON.parse(last_response.body)
      parsed.length.should == 1
    end

    it "should support json post data" do

      @bus.publish('foo', 'bar')

      header "Content-Type", "application/json"
      post "/message-bus/ABCD", { '/foo' => -1}.to_json
      last_response.should be_ok
      parsed = JSON.parse(last_response.body)
      parsed.length.should == 1
      parsed[0]["channel"].should == "/__status"
      parsed[0]["data"]["/foo"].should ==@bus.last_id("/foo")

    end
  end

end
