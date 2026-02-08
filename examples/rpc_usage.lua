-- Example usage of acp.rpc module
-- This shows how to use the custom JSON-RPC client for Agent Client Protocol

local rpc = require('acp.rpc')

-- Example 1: Basic usage
local function example_basic()
    -- Define handlers for messages from the agent
    local dispatchers = {
        -- Handle notifications from agent (one-way messages)
        notification = function(method, params)
            if method == "session/update" then
                print("Session update:", vim.inspect(params))
            elseif method == "$/cancelRequest" then
                print("Request cancelled")
            end
        end,
        
        -- Handle requests from agent (must return response)
        server_request = function(method, params)
            if method == "fs/read_text_file" then
                -- Read file and return content
                local ok, lines = pcall(vim.fn.readfile, params.path)
                if ok then
                    return { content = table.concat(lines, "\n") }, nil
                else
                    return nil, rpc.rpc_response_error(
                        rpc.ErrorCodes.ResourceNotFound,
                        "Failed to read file: " .. params.path
                    )
                end
            elseif method == "fs/write_text_file" then
                -- Write file
                local ok = pcall(vim.fn.writefile, 
                    vim.split(params.content, "\n"),
                    params.path
                )
                if ok then
                    return {}, nil  -- Empty success response
                else
                    return nil, rpc.rpc_response_error(
                        rpc.ErrorCodes.InternalError,
                        "Failed to write file"
                    )
                end
            end
            
            -- Method not found
            return nil, rpc.rpc_response_error(
                rpc.ErrorCodes.MethodNotFound,
                "Method not found: " .. method
            )
        end,
        
        -- Handle process exit
        on_exit = function(code, signal)
            print(string.format("Agent exited with code %d, signal %d", code, signal))
        end,
        
        -- Handle errors
        on_error = function(code, err)
            vim.notify("RPC Error: " .. err, vim.log.levels.ERROR)
        end,
    }
    
    -- Start the agent
    local client = rpc.start(
        { "path/to/agent", "--arg1", "value1" },  -- Command to start agent
        dispatchers,
        {
            cwd = vim.fn.getcwd(),  -- Working directory
            env = {                  -- Environment variables (optional)
                HOME = vim.env.HOME,
                PATH = vim.env.PATH,
            }
        }
    )
    
    return client
end

-- Example 2: Initialize and create session
local function example_initialize_and_session()
    local client = example_basic()
    
    -- Send initialize request
    client.request("initialize", {
        protocolVersion = 1,
        clientInfo = {
            name = "acp.nvim",
            version = "0.1.0"
        },
        clientCapabilities = {
            fs = {
                readTextFile = true,
                writeTextFile = true
            },
            terminal = true,
        }
    }, function(err, result)
        if err then
            vim.notify("Initialize failed: " .. rpc.format_rpc_error(err), vim.log.levels.ERROR)
            return
        end
        
        print("Agent initialized:", vim.inspect(result))
        print("Protocol version:", result.protocolVersion)
        print("Agent info:", vim.inspect(result.agentInfo))
        
        -- Now create a session
        client.request("session/new", {
            cwd = vim.fn.getcwd(),
            mcpServers = {}  -- No MCP servers for now
        }, function(err2, result2)
            if err2 then
                vim.notify("Session creation failed: " .. rpc.format_rpc_error(err2), vim.log.levels.ERROR)
                return
            end
            
            local session_id = result2.sessionId
            print("Session created:", session_id)
            
            -- Send a prompt
            client.request("session/prompt", {
                sessionId = session_id,
                prompt = {
                    {
                        text = "Hello, can you help me write a function?",
                        type = "text"
                    }
                }
            }, function(err3, result3)
                if err3 then
                    vim.notify("Prompt failed: " .. rpc.format_rpc_error(err3), vim.log.levels.ERROR)
                    return
                end
                
                print("Prompt response:", vim.inspect(result3))
                print("Stop reason:", result3.stopReason)
            end)
        end)
    end)
    
    return client
end

-- Example 3: Send notifications
local function example_notifications(client, session_id)
    -- Cancel an operation (notification - no response expected)
    client.notify("session/cancel", {
        sessionId = session_id
    })
    
    print("Cancellation notification sent")
end

-- Example 4: Object-oriented client wrapper
local Client = {}
Client.__index = Client

function Client.new(agent_name, cmd, opts)
    local self = setmetatable({
        agent_name = agent_name,
        session_id = nil,
        _rpc_client = nil,
    }, Client)
    
    opts = opts or {}
    
    local dispatchers = {
        notification = function(method, params)
            self:_handle_notification(method, params)
        end,
        server_request = function(method, params)
            return self:_handle_request(method, params)
        end,
        on_exit = function(code, signal)
            self:_on_exit(code, signal)
        end,
        on_error = function(code, err)
            self:_on_error(code, err)
        end,
    }
    
    self._rpc_client = rpc.start(cmd, dispatchers, {
        cwd = opts.cwd or vim.fn.getcwd(),
        env = opts.env,
    })
    
    return self
end

function Client:initialize(callback)
    self._rpc_client.request("initialize", {
        protocolVersion = 1,
        clientInfo = {
            name = "acp.nvim",
            version = "0.1.0"
        },
        clientCapabilities = {
            fs = {
                readTextFile = true,
                writeTextFile = true
            },
            terminal = true,
        }
    }, callback)
end

function Client:new_session(params, callback)
    self._rpc_client.request("session/new", params, function(err, result)
        if not err and result then
            self.session_id = result.sessionId
        end
        callback(err, result)
    end)
end

function Client:prompt(text, callback)
    if not self.session_id then
        callback(rpc.rpc_response_error(-1, "No active session"))
        return
    end
    
    self._rpc_client.request("session/prompt", {
        sessionId = self.session_id,
        prompt = {
            { text = text, type = "text" }
        }
    }, callback)
end

function Client:cancel()
    if not self.session_id then
        return
    end
    
    self._rpc_client.notify("session/cancel", {
        sessionId = self.session_id
    })
end

function Client:terminate()
    self._rpc_client.terminate()
end

-- Private methods
function Client:_handle_notification(method, params)
    if method == "session/update" then
        -- Emit autocommand for UI to handle
        vim.api.nvim_exec_autocmds("User", {
            pattern = "AcpSessionUpdate",
            data = {
                agent_name = self.agent_name,
                session_id = params.sessionId,
                update = params.update,
            }
        })
    end
end

function Client:_handle_request(method, params)
    if method == "fs/read_text_file" then
        local ok, lines = pcall(vim.fn.readfile, params.path)
        if ok then
            return { content = table.concat(lines, "\n") }, nil
        else
            return nil, rpc.rpc_response_error(
                rpc.ErrorCodes.ResourceNotFound,
                "Failed to read file: " .. params.path
            )
        end
    elseif method == "fs/write_text_file" then
        local ok = pcall(vim.fn.writefile, 
            vim.split(params.content, "\n"),
            params.path
        )
        if ok then
            return {}, nil
        else
            return nil, rpc.rpc_response_error(
                rpc.ErrorCodes.InternalError,
                "Failed to write file"
            )
        end
    end
    
    return nil, rpc.rpc_response_error(
        rpc.ErrorCodes.MethodNotFound,
        "Method not found: " .. method
    )
end

function Client:_on_exit(code, signal)
    print(string.format("[%s] Agent exited: code=%d signal=%d", self.agent_name, code, signal))
end

function Client:_on_error(code, err)
    vim.notify(
        string.format("[%s] RPC Error: %s", self.agent_name, err),
        vim.log.levels.ERROR
    )
end

-- Example 5: Using the OOP wrapper
local function example_oop()
    local client = Client.new("opencode", {
        "opencode", "acp"
    })
    
    client:initialize(function(err, result)
        if err then
            vim.notify("Failed to initialize: " .. rpc.format_rpc_error(err), vim.log.levels.ERROR)
            return
        end
        
        print("Initialized:", vim.inspect(result))
        
        client:new_session({
            cwd = vim.fn.getcwd(),
            mcpServers = {}
        }, function(err2, result2)
            if err2 then
                vim.notify("Failed to create session: " .. rpc.format_rpc_error(err2), vim.log.levels.ERROR)
                return
            end
            
            print("Session created:", result2.sessionId)
            
            client:prompt("Write a hello world function", function(err3, result3)
                if err3 then
                    vim.notify("Prompt failed: " .. rpc.format_rpc_error(err3), vim.log.levels.ERROR)
                    return
                end
                
                print("Response received:", vim.inspect(result3))
            end)
        end)
    end)
    
    return client
end

-- Export examples
return {
    example_basic = example_basic,
    example_initialize_and_session = example_initialize_and_session,
    example_notifications = example_notifications,
    example_oop = example_oop,
    Client = Client,
}
