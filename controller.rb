require 'socket'
require 'open-uri'
require 'json'
require './helpers.rb'
require './requests.rb'
require './arduino_client.rb'
require './public_server.rb'
require './model.rb'
require './model_base.rb'
require './controller_helpers.rb'

module ArduinoGateway
  module Control

    class Controller
        include ::ArduinoGateway::Helpers
        include ::ArduinoGateway::Control::ControlHelpers
        attr_accessor :timer

        def initialize(public_server)
          @public_server = public_server
          @public_server.register_controller(self)
          Interface::ArduinoClient.register_controller(self)
          @timer = Timer.new
          @active_requests = {}
          
          # create a thread to listen to keyboard commands
          @key_listener = Thread.new do
            begin
          		puts "[Controller:initializer] starting key listener thread"
              while(true)       
            		input = STDIN.gets.chomp
            		puts "[Controller:@key_listener] processing your input [#{input}]"
            		if input.include?("X") then
            			puts "[Controller:@key_listener] closing port #{@public_server.public_port_number} and exiting app."
            			@public_server.stop
            			exit
            		end
            	end
          	rescue => e
          	  puts "[Controller:@key_listener] thread stopped #{e.backtrace}"
          	end
          end

          register_arduinos ("arduino_addrs.json")
        end # initialize method
        ######################################


        ############################################################################
        ############################################################################
        # INITIALIZE DATATABLES
        # register arduinos, services and service instances
        ############################################################################

        ######################################
        # REGISTER_ARDUINOS
        # Description: reads the arduino_addrs.json file and registers arduinos described
        #              in that files. 
        # Arguments: accepts a string that holds a filename
        # Returns: no specific return value expected
        def register_arduinos(filename)
          File.open filename do |json_file|
            JSON.parse(json_file.read).each do |cur_arduino|
              arduino = {name: cur_arduino["name"], ip: cur_arduino["ip"], port: cur_arduino["port"]}
              register_arduino(arduino)
            end # end JSON.parse
          end # close file          
        end # end register_arduinos
        ######################################

        ######################################
        # REGISTER_ARDUINO
        # Description: registers new arduinos into the the ResourceDevice datatable
        # Arguments: accepts hash keys with key/value pairs for name, ip and port
        # Returns: no specific return value expected        
        def register_arduino(arduino)
          return false unless address_valid?(arduino)
          device = ::ArduinoGateway::Model::ModelTemplates::ResourceDevice.new arduino
          arduino[:device_id] = device.id
          public_request_id, request_string = device.id * -1, "GET /resource_info"
          request = RestfulRequest.new(public_request_id, request_string, arduino)

          @active_requests[public_request_id] = {public_request: request_string, 
                                          received_on: Time.now.to_i,
                                          arduino_requests: {arduino[:name] => request},
                                          arduino_responses: {},
                                          public_response: ""}
          make_request request
        end # register_arduino method
        ######################################

        ######################################
        # REGISTER_SERVICES
        # Description: parses info_requests that are made when arduinos are registered. Method 
        #              saves the services into the ResourceService datatable (via get_service_id 
        #              method) and saves service instances into ResourceInstance datatable
        # Arguments: a RestfulRequest object
        # Returns: no specific return value
        def register_services(request)
          return unless request.is_a? RestfulRequest
          @active_requests[request.id][:arduino_responses][request.address[:name]].match /^(?:[A-Za-z].*\n)*([\[|\{](?:.*\n*)*)\n/
          return unless services_json = $1

          JSON.parse(services_json).each do |services|
            services["resource_name"].match /(^\D*)(?:_\d)*$/
            return unless service_type_name = $1
            puts_debug "[Controller:register_services] current resource name matched '#{$1}'"
            
            # get service id by finding existing service id, or adding a new service if needed 
            service_id = get_service_id(service_type_name)
            new_instance = {name: services["resource_name"], 
                           post_enabled: services["post_enabled"],
                           range_min: services["range"]["min"],
                           range_max: services["range"]["max"],
                           device_id: request.address[:device_id], service_type_id: service_id}
            ::ArduinoGateway::Model::ModelTemplates::ResourceInstance.new new_instance            
          end
        end # register_services method
        ######################################
        

        ############################################################################
        ############################################################################
        # PROCESS METHODS
        # methods called by external classes, such as public_server and arduino_client
        ############################################################################

        ######################################
        # PROCESS_REQUEST 
        # Description: processes public request and determines which arduino requests need 
        #              to be created, then creates an array with the appropriate requests
        # Argument: id of the public request
        # Returns: 
        def process_request(public_request_id)      

          # parse the URL into verb, resources, options, and body
          @active_requests[public_request_id][:public_request].match /(GET|POST) \/(\S*)(.*)^(.*)\Z/m
          parsed_requests, new_requests, request_resources = [$1, $2, $3, $4], {}, $2

          ## handle / (GENERIC) resource requests ##
          if request_resources.empty?
            new_requests = process_generic_request(parsed_requests, public_request_id)

          ## handle /TEST_POST/ resource request ##
          elsif request_resources.match /test_post/
            new_requests = process_form_request(parsed_requests, public_request_id)
            
          ## handle ALL OTHER requests ##
          else
            parsed_resources = parsed_requests[1].split("/")
            device_match = ::ArduinoGateway::Model::ModelTemplates::ResourceDevice.find_by_name(parsed_resources[0])

            # handle requests for DEVICE-BASED SERVICES
            unless device_match.empty?
              new_requests = process_device_request(parsed_requests, parsed_resources, device_match, public_request_id)                            
            # handle requests for SERVICES ACCROSS DEVICES
            else 
              new_requests = process_service_request(parsed_requests, parsed_resources, device_match, public_request_id)
            end

          end # else related to ALL OTHER requests

          new_requests.each  { | name, request | make_request request }
          @active_requests[public_request_id][:arduino_requests] = new_requests
        end # process_request
        ######################################              

        ######################################              
        # HANDLE_GENERIC_REQUEST
        #
        def process_generic_request(parsed_request, public_request_id)
          request_verb, request_resources = parsed_request[0], parsed_request[1]
          request_options, request_body = parsed_request[2], parsed_request[3]
          device_resources, new_requests = ["json"], {}
          ::ArduinoGateway::Model::ModelTemplates::ResourceDevice.find_all().each do | arduino |
            new_request_string = "#{request_verb} /#{device_resources.join("/")}#{request_options}#{request_body}"
            address = {name: arduino.name, ip: arduino.ip, port: arduino.port.to_i, device_id: arduino.id.to_i}
            new_requests[arduino.name] = RestfulRequest.new(public_request_id, new_request_string, address)                            
          end
          new_requests
        end
        ######################################              

        ######################################              
        # HANDLE_GENERIC_REQUEST
        #
        def process_form_request(parsed_request, public_request_id)
          request_verb, request_resources = parsed_request[0], parsed_request[1]
          request_options, request_body = parsed_request[2], parsed_request[3]
          device_info, device_resources, new_requests = {}, ["json"], {}
          header, body = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n", {}

          ::ArduinoGateway::Model::ModelTemplates::ResourceDevice.find_all().each do | arduino |
            body[arduino.id.to_i] = "<form style='display:inline;' action='/#{arduino.name}' method='POST'>"
          end
          ::ArduinoGateway::Model::ModelTemplates::ResourceInstance.find_by_post_enabled("true").each do | service |
            body[service.device_id] += "#{service.name}: <input type='text' name='#{service.name}'/><br />"
          end
          body.each_key do | key |
            body[key] += "<input type='submit' value='update state'/></form><br/>"
          end 

          @public_server.respond "#{header}#{body.values.flatten.join}", public_request_id
          @active_requests.delete(public_request_id) 
        end
        ######################################              

        ######################################              
        # HANDLE_DEVICE_REQUEST
        #
        def process_device_request(parsed_request, parsed_resources, device_match, public_request_id)
          request_verb, request_resources = parsed_request[0], parsed_request[1]
          request_options, request_body = parsed_request[2], parsed_request[3]
          device_info, device_resources, new_requests = {}, ["json"], {}

          parsed_resources.shift 
          device_info = {name: device_match[0].name.to_s, id: device_match[0].id, 
                         ip: device_match[0].ip, port: device_match[0].port}

          # handle service instance requests
          service_instance_match = ::ArduinoGateway::Model::ModelTemplates::ResourceInstance.find_by_device_id(device_info[:id])              
          if !service_instance_match.empty?
            parsed_resources.each do | service_name |
              service_instance_match.each do | service_instance |
                device_resources << service_name if service_instance.name.to_s.eql? service_name
              end
            end
          end

          # handle generic service requests
          parsed_resources.each do | service_name |
            generic_service_match = ::ArduinoGateway::Model::ModelTemplates::ResourceService.find_by_name(service_name)              
            if !generic_service_match.empty?
              service_id = generic_service_match[0].id.to_i
              service_instance_match.each do | service_instance |
                device_resources << service_instance.name if service_instance.service_type_id == service_id
              end
            end
          end

          new_request_string = "#{request_verb} /#{device_resources.join("/")}#{request_options}#{request_body}"
          new_requests[device_info[:name]] = RestfulRequest.new(public_request_id, new_request_string, device_info)              
          new_requests
        end
        ######################################              

        ######################################              
        # HANDLE_SERVICE_REQUEST
        #
        def process_service_request(parsed_request, parsed_resources, device_match, public_request_id)
          request_verb, request_resources = parsed_request[0], parsed_request[1]
          request_options, request_body = parsed_request[2], parsed_request[3]
          device_info, device_resources, new_requests = {}, ["json"], {}
          services_by_device = {}
           
           # loop through parsed public request to identify services being requested
           parsed_resources.each do | service_name |
          
             # look for specific service requests using service name
             service_instance_match = ::ArduinoGateway::Model::ModelTemplates::ResourceInstance.find_by_name(service_name)              
             service_instance_match.each do | service_instance |
               if services_by_device[service_instance.device_id.to_i] 
                 services_by_device[service_instance.device_id.to_i] << service_instance.name.to_s
               else 
                 services_by_device[service_instance.device_id.to_i] = [service_instance.name.to_s]
               end
             end # service_instance_match.each iterator
          
             # look for general service requests
             generic_service_match = ::ArduinoGateway::Model::ModelTemplates::ResourceService.find_by_name(service_name)              
             unless generic_service_match.empty?
               service_id = generic_service_match[0].id.to_i
               # find the individual service instances using service_id
               service_instance_match = ::ArduinoGateway::Model::ModelTemplates::ResourceInstance.find_by_service_type_id(service_id)              
               service_instance_match.each do | service_instance |
                 if services_by_device[service_instance.device_id.to_i] 
                   services_by_device[service_instance.device_id.to_i] << service_instance.name.to_s
                 else 
                   services_by_device[service_instance.device_id.to_i] = [service_instance.name.to_s]
                 end
               end # service_instance_match.each iterator
             end # unless generic_service_match.empty?
           end # parsed_resources.each iterator
          
           # loop services by device to create private requests 
           services_by_device.each do | device , services |
             services.each { | service | device_resources << service }
             device_resources.uniq!
             device_match = ::ArduinoGateway::Model::ModelTemplates::ResourceDevice.find_by_id(device.to_i)
             unless device_match.empty?
               device_info = {name: device_match[0].name.to_s, id: device_match[0].id, 
                              ip: device_match[0].ip, port: device_match[0].port}
               new_request_string = "#{request_verb} /#{device_resources.join("/")}#{request_options}#{request_body}"
               new_requests[device_info[:name]] = RestfulRequest.new(public_request_id, new_request_string, device_info)              
             end # unless device_match.empty?  
           end # services_by_device.each
           new_requests
        end



        ############################################################################
        ############################################################################
        # INCOMING API METHODS
        # methods called by external classes, such as public_server and arduino_client
        ############################################################################

        ######################################              
        # REGISTER_REQUEST
        # Description: called by public server to register new public request
        # Arguments: a request string, followed by a request id
        # Returns: no specific return value
        def register_request(request_string, public_request_id)      

          # if this is a GET or POST request then process the request
          if request_string.match /(GET|POST)/
            puts_debug "[Controller:register_request] new request, id: #{public_request_id}, content: #{request_string}"
            @active_requests[public_request_id] = {public_request: request_string, received_on: Time.now.to_i,
                                            arduino_requests: {}, arduino_responses: {}, public_response: ""}
            process_request(public_request_id) 

            # start a timer set code to be executed when the timer is up
            @timer.new_timer(1) do
              process_response public_request_id unless @active_requests[public_request_id].nil?
            end # end timer

          # if this is NOT a GET or POST request then respond with an error message
          else
            @public_server.respond error_msg(:request_not_supported), public_request_id
          end
        end # register_request method
        ######################################              
        
        ######################################
        # REGISTER_RESPONSE
        # Description: called by the ArduinoClient class to register responses to request
        def register_response(response, request)

          @active_requests[request.id][:arduino_responses][request.address[:name]] = response                       

          # if reponse is to an info_request then register services
          if request.id < 0 
            register_services request          

          # else handle response like a normal resource request
          else 
            requests = @active_requests[request.id][:arduino_requests].length
            responses = @active_requests[request.id][:arduino_responses].length
            puts "[Controller:register_response] number of requests #{requests}, and responses #{responses}"
            if responses >= requests
              puts "[Controller:register_response] responses received, id: #{request.id}, content: #{@active_requests[request.id]}"
              # process_response(@active_requests[request.id][:arduino_responses], request.id) 
              process_response request.id
              # @active_requests.delete(request.id)              
            end
          end
        end # register_response method
        ######################################


        ############################################################################
        ############################################################################
        # OUTGOING API METHODS
        # methods called that call external classes such as public_server and arduino_client
        ############################################################################

        ######################################
        # MAKE_REQUEST
        # method that sends individual requests to specific devices
        def make_request(new_request)          
            puts "[Controller:make_request] request '#{new_request.id}' will be submitted to arduino"
            return error_msg(:arduino_address) unless address_valid?(new_request.address)
         		return Interface::ArduinoClient.register_request(new_request)
            rescue Exception => error; return error_msg(:timeout, error)
        end

        ######################################
        # PROCESS_RESPONSE 
        # Method called when all responses have been received or when request times out
        # 1. iterate through response in order to create a single response string
        # 2. respond to public request by calling the 
        def process_response(public_request_id)      

          # if data was received then 
          unless @active_requests[public_request_id][:arduino_responses].empty?            
            public_responses = []
            http_header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
            public_response = "#{http_header}[\r\n"

            # create a hash key with device/response pairs
            @active_requests[public_request_id][:arduino_responses].each do | device, response |
              response.match /.*?([\[\{].*[\}\]]+)/m
              public_responses << "{\r\n#{device}:#{$1}\r\n}"
            end

            # convert device/response pairs from hash into a json formatted string
            public_responses.each_with_index do | response, index |
              public_response += response
              if index == public_responses.length - 1 
                public_response += "\r\n]" 
              else 
                public_response += ",\r\n" 
              end 
            end

            # respond back to public request with data in json format
            puts "[Controller:process_response] public response #{public_response}"
            @active_requests[public_request_id][:public_response] = public_response
            @public_server.respond @active_requests[public_request_id][:public_response], public_request_id

          else
            http_header = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n"
            public_response = "#{http_header}Resources Not Found"
            @public_server.respond public_response, public_request_id

          end
          
          @active_requests.delete(public_request_id) unless @active_requests[public_request_id][:arduino_responses].empty?            
                                  
        end # process_response method

    end # Controller class

  end # Control module
end # ArduinoGateway module
