
namespace app

include std/convert.e
include std/error.e
include std/map.e
include std/io.e
include std/pretty.e
include std/regex.e
include std/search.e
include std/sequence.e
include std/net/url.e
include std/text.e
include std/types.e
include std/utils.e

include mvc/template.e

--
-- Route Parsing
--

-- variable name only
constant re_varonly = regex:new( `^<([_a-zA-Z][_a-zA-Z0-9]*)>$` )

-- variable with type
constant re_vartype = regex:new( `^<([_a-zA-Z][_a-zA-Z0-9]*):(atom|integer|string|object)>$` )

-- type identifier patterns
map m_regex = map:new()
map:put( m_regex, "atom",    regex:new(`([-]?[0-9]*\.[0-9]+)`) )
map:put( m_regex, "integer", regex:new(`([-]?[0-9]+)`) )
map:put( m_regex, "string",  regex:new(`([\w\d\.\/]+)`) )
map:put( m_regex, "object",  regex:new(`([^\s\/]+)`) )

--
-- Route Lookup
--

-- name -> pattern lookup
export map m_names = map:new()

-- pattern -> data storage
export map m_routes = map:new()

-- name -> value headers
export map m_headers = map:new()

--
-- HTTP Status Codes
--

-- status -> description
map m_status = map:new_from_kvpairs({
	-- 1xx Information Response
	{ 100, "Continue" },
	{ 101, "Switching Protocols" },
	{ 102, "Processing" },
	{ 103, "Early Hints" },
	-- 2xx Success
	{ 200, "OK" },
	{ 201, "Created" },
	{ 202, "Accepted" },
	{ 203, "Non-Authoritative Information" },
	{ 204, "No Content" },
	{ 205, "Reset Content" },
	{ 206, "Partial Content" },
	{ 207, "Multi-Status" },
	{ 208, "Already Reported" },
	{ 226, "IM Used" },
	-- 3xx Redirection
	{ 300, "Multiple Choices" },
	{ 301, "Moved Permanently" },
	{ 302, "Found" },
	{ 303, "See Other" },
	{ 304, "Not Modified" },
	{ 305, "Use Proxy" },
	{ 306, "Switch Proxy" },
	{ 307, "Temporary Redirect" },
	{ 308, "Permanent Redirect" },
	-- 4xx Client Errors
	{ 400, "Bad Request" },
	{ 401, "Unauthorized" },
	{ 403, "Forbidden" },
	{ 404, "Not Found" },
	{ 405, "Method Not Allowed" },
	{ 406, "Not Acceptable" },
	{ 407, "Proxy Authentication Required" },
	{ 408, "Request Timeout" },
	{ 409, "Conflict" },
	{ 410, "Gone" },
	{ 411, "Length Required" },
	{ 412, "Precondition Failed" },
	{ 413, "Payload Too Large" },
	{ 414, "URI Too Long" },
	{ 415, "Unsupported Media Type" },
	{ 416, "Range Not Satisfied" },
	{ 417, "Expectation Failed" },
	{ 418, "I'm a teapot" },
	{ 421, "Misdirected Request" },
	{ 422, "Unprocessable Entity" },
	{ 423, "Locked" },
	{ 424, "Failed Dependency" },
	{ 426, "Upgrade Required" },
	{ 428, "Precondition Required" },
	{ 429, "Too Many Requests" },
	{ 431, "Request Header Fields Too Large" },
	{ 451, "Unavailable for Legal Reasons" },
	-- 5xx Server Errors
	{ 500, "Internal Server Error" },
	{ 501, "Not Implemented" },
	{ 502, "Bad Gateway" },
	{ 503, "Service Unavailable" },
	{ 504, "Gateway Timeout" },
	{ 505, "HTTP Version Not Supported" },
	{ 506, "Variant Also Negotiates" },
	{ 507, "Insufficient Storage" },
	{ 508, "Loop Detected" },
	{ 510, "Not Extended" },
	{ 511, "Network Authentication Required" }
})

--
-- Error Page Template
--

constant DEFAULT_ERROR_PAGE = """
<!DOCTYPE html>
<html>
<head>
  <title>{{ title }}</title>
</head>
<body>
  <h1>{{ title }}</h1>
  <p>{{ message }}</p>
  <hr>
  <p>{{ signature }}</p>
  </body>
</html>

"""

map m_error_page = map:new()

--
-- Returns the error page template defined for the response code.
--
public function get_error_page( integer code )
	return map:get( m_error_page, code, DEFAULT_ERROR_PAGE )
end function

--
-- Set the error page template defined for the response code.
--
public procedure set_error_page( integer code, sequence template )
	map:put( m_error_page, code, template )
end procedure

--
-- Better environment variables
--

public enum
    AS_STRING,
    AS_INTEGER,
    AS_NUMBER

function as_default( integer as_type )

    if as_type = AS_STRING then
        return ""
    end if

    return 0
end function

--
-- Look up an environment variable and optionally convert it to another type.
--
public function getenv( sequence name, integer as_type = AS_STRING, object default = as_default(as_type) )

    object value = eu:getenv( name )

    if atom( value ) then
        return default
    end if

    if as_type = AS_INTEGER then
        value = to_integer( value )

    elsif as_type = AS_NUMBER then
        value = to_number( value )

    end if

    return value
end function

--
-- Variables
--

--
-- Return TRUE if an item looks like a variable.
--
public function is_variable( sequence item )
    return regex:is_match( re_varonly, item )
        or regex:is_match( re_vartype, item )
end function

--
-- Parse a variable and return its name and type.
--
public function parse_variable( sequence item )

    sequence var_name = ""
    sequence var_type = ""

    if regex:is_match( re_varonly, item ) then

        sequence matches = regex:matches( re_varonly, item )

        var_name = matches[2]
        var_type = "object"

    elsif regex:is_match( re_vartype, item ) then

        sequence matches = regex:matches( re_vartype, item )

        var_name = matches[2]
        var_type = matches[3]

    end if

    return {var_name,var_type}
end function

--
-- Set an outgoing header value.
--
public procedure header( sequence name, object value, object data = {} )

	if atom( value ) then
        value = sprint( value )

	elsif string( value ) then
        value = sprintf( value, data )

    elsif sequence_array( value ) and length( value ) = 1 then
        value = map:get( m_headers, name, {} ) & value

    end if

	map:put( m_headers, name, value )

end procedure

--
-- Routing
--

enum
    ROUTE_PATH,
    ROUTE_NAME,
    ROUTE_VARS,
    ROUTE_RID

--
-- Build a URL from a route using optional response object.
--
public function url_for( sequence name, object response = {} )

	sequence default = "#" & name

	regex pattern = map:get( m_names, name, "" )
	if length( pattern ) = 0 then return default end if

	sequence data = map:get( m_routes, pattern, {} )
	if length( data ) = 0 then return default end if

	sequence path = data[ROUTE_PATH]

	if map( response ) then

	    sequence parts = stdseq:split( path[2..$], "/" )
		sequence varname, vartype

	    for i = 1 to length( parts ) do
    	    if is_variable( parts[i] ) then

        	    {varname,vartype} = parse_variable( parts[i] )

            	if length( varname ) and length( vartype ) then
					object value = map:get( response, varname, 0 )
					if atom( value ) then value = sprint( value ) end if
					parts[i] = value
    	        end if

        	end if
	    end for

		path = "/" & stdseq:join( parts, "/" )

	end if

	return path
end function

--
-- Return an HTTP redirect code and a link in case that doesn't work.
--
public function redirect( sequence url, integer code = 302 )

	sequence message = sprintf( `Please <a href="%s">click here</a> if you are not automatically redirected.`, {url} )

	header( "Location", "%s", {url} )

	return response_code( code, "Redirect", message )
end function

--
-- Return a response codw with optional status (the descrption) and message (displayed on the page).
--
public function response_code( integer code, sequence status = "", sequence message = "" )

	if length( status ) = 0 then
		status = map:get( m_status, code, "Undefined" )
	end if

	sequence title = sprintf( "%d %s", {code,status} )
	sequence signature = getenv( "SERVER_SIGNATURE" )

	sequence template = get_error_page( code )

	object response = map:new()
	map:put( response, "title",     title )
	map:put( response, "status",    status )
	map:put( response, "message",   message )
	map:put( response, "signature", signature )

	header( "Status", "%d %s", {code,status} )

	return parse_template( template, response )
end function

--
-- Convert a route path to a simple name.
--
public function get_route_name( sequence path )

	if equal( "*", path ) then
		return "default"

    elsif not search:begins( "/", path ) then
        return ""

    end if

    sequence parts = stdseq:split( path[2..$], "/" )
    if length( parts ) = 0 then
        return ""
    end if

    return stdseq:retain_all( "_abcdefghijklmnopqrstuvwxyz", parts[1] )
end function

--
-- Assign a route path to a handler function.
--
public procedure route( sequence path, sequence name = get_route_name(path), integer func_id = routine_id(name) )

    if func_id = -1 then
        error:crash( "route function '%s' not found", {name} )
    end if

	if equal( "*", path ) then
		regex pattern = regex:new( "^/.+$" )
		map:put( m_names, name, pattern )
		map:put( m_routes, pattern, {path,name,{},func_id} )
		return

    elsif map:has( m_routes, path ) then
        return

    elsif not search:begins( "/", path ) then
        return

    end if

    sequence vars = {""}
    sequence varname, vartype

    sequence parts = stdseq:split( path[2..$], "/" )

    for i = 1 to length( parts ) do

        if is_variable( parts[i] ) then

            {varname,vartype} = parse_variable( parts[i] )

            if length( varname ) and length( vartype ) then
                vars = append( vars, {varname,vartype} )
                parts[i] = map:get( m_regex, vartype, "" )
            end if

        end if

    end for

    regex pattern = regex:new( "^/" & stdseq:join( parts, "/" ) & "$" )

	map:put( m_names, name, pattern )
    map:put( m_routes, pattern, {path,name,vars,func_id} )

end procedure

--
-- Hooks
--

enum
	HOOK_NAME,
	HOOK_LIST

sequence m_hooks = {}

public constant
	HOOK_APP_START      = new_hook_type( "app_start"      ),
	HOOK_APP_END        = new_hook_type( "app_end"        ),
	HOOK_REQUEST_START  = new_hook_type( "request_start"  ),
	HOOK_REQUEST_END    = new_hook_type( "request_end"    ),
	HOOK_HEADERS_START  = new_hook_type( "headers_start"  ),
	HOOK_HEADERS_END    = new_hook_type( "headers_end"    ),
	HOOK_RESPONSE_START = new_hook_type( "response_start" ),
	HOOK_RESPONSE_END   = new_hook_type( "response_end"   ),
$

--
-- Add new hook type.
--
public function new_hook_type( sequence name )

	sequence list = {}
	m_hooks = append( m_hooks, {name,list} )

	return length( m_hooks )
end function

--
-- Insert a new hook.
--
public procedure insert_hook( integer hook_type, sequence func_name, integer func_id = routine_id(func_name) )
	m_hooks[hook_type][HOOK_LIST] = append( m_hooks[hook_type][HOOK_LIST], {func_name,func_id} )
end procedure

--
-- Run a list of hooks.
--
public function run_hooks( integer hook_type )

	object func_name, func_id
	integer exit_code = 0

	sequence hook_name = m_hooks[hook_type][HOOK_NAME]
	sequence hook_list = m_hooks[hook_type][HOOK_LIST]

	for i = 1 to length( hook_list ) do
		{func_name,func_id} = hook_list[i]

		exit_code = call_func( func_id, {} )
		if exit_code then exit end if

	end for

	return exit_code
end function

--
-- Requests
--

--
-- Parse the path and query string for available variables.
--
public function parse_request( sequence vars, sequence matches, sequence path_info, sequence request_method, sequence query_string )

    if length( vars ) != length( matches ) then
        error:crash( "route parameters do not match (%d != %d)",
            { length(vars), length(matches) } )
    end if

    map request = parse_querystring( query_string )
    map:put( request, "PATH_INFO", path_info )
    map:put( request, "REQUEST_METHOD", request_method )
    map:put( request, "QUERY_STRING", query_string )

    object varname, vartype, vardata

    for j = 2 to length( vars ) do
        {varname,vartype} = vars[j]

        switch vartype do
            case "atom" then
                vardata = to_number( matches[j] )
            case "integer" then
                vardata = to_integer( matches[j] )
            case else
                vardata = matches[j]
        end switch

        map:put( request, varname, vardata )

    end for

    return request
end function

--
-- Parse an incoming request, call its handler, and return the response.
--
public function handle_request( sequence path_info, sequence request_method, sequence query_string )

    integer route_found = 0
	integer default_route = 0
	sequence response = ""
    sequence patterns = map:keys( m_routes )

	integer exit_code

	exit_code = run_hooks( HOOK_REQUEST_START )
	if exit_code then return "" end if

    for i = 1 to length( patterns ) do
        sequence pattern = patterns[i]

        object path, name, vars, func_id
        {path,name,vars,func_id} = map:get( m_routes, pattern )

		if equal( "*", path ) then
			default_route = i
			continue
		end if

        if not regex:is_match( pattern, path_info ) then
            continue
        end if

        sequence matches = regex:matches( pattern, path_info )
        object request = parse_request( vars, matches,
			path_info, request_method, query_string )

		exit_code = run_hooks( HOOK_RESPONSE_START )
		if exit_code then return "" end if

        header( "Content-Type", "text/html" )
        response = call_func( func_id, {request} )

		exit_code = run_hooks( HOOK_RESPONSE_END )
		if exit_code then return "" end if

        route_found = i
        exit

    end for

	if not route_found then

		if default_route then

			sequence pattern = patterns[default_route]

	        object path, name, vars, func_id
	        {path,name,vars,func_id} = map:get( m_routes, pattern )

			object request = parse_request( {}, {},
				path_info, request_method, query_string )

			exit_code = run_hooks( HOOK_RESPONSE_START )
			if exit_code then return "" end if

	        header( "Content-Type", "text/html" )
	        response = call_func( func_id, {request} )

			exit_code = run_hooks( HOOK_RESPONSE_END )
			if exit_code then return "" end if

		else

			response = response_code( 404, "Not Found",
				"The requested URL was not found on this server."
			)

		end if

	end if

	header( "Content-Length", length(response) )

	exit_code = run_hooks( HOOK_REQUEST_END )
	if exit_code then return "" end if

	return response
end function

--
-- Entry point for the application. Performs basic setup and calls handle_request().
--
public procedure run()

	integer exit_code

	exit_code = run_hooks( HOOK_APP_START )
	if exit_code then return end if

    sequence path_info      = getenv( "PATH_INFO" )
	sequence request_method = getenv( "REQUEST_METHOD" )
	sequence query_string   = getenv( "QUERY_STRING" )
	integer content_length  = getenv( "CONTENT_LENGTH", AS_INTEGER, 0 )

	if equal( request_method, "POST" ) and content_length != 0 then
		query_string = get_bytes( STDIN, content_length )
	end if

    add_function( "url_for", {
        {"name"},
        {"response",0}
    }, routine_id("url_for") )

	sequence response = handle_request( path_info, request_method, query_string )

	exit_code = run_hooks( HOOK_HEADERS_START )
	if exit_code then return end if

	sequence headers = map:keys( m_headers )

	for i = 1 to length( headers ) do

		object value = map:get( m_headers, headers[i] )

		if sequence_array( value ) then
            for j = 1 to length( value ) do
                printf( STDOUT, "%s: %s\r\n", {headers[i],value[j]} )
            end for
		else
            if atom( value ) then value = sprint( value ) end if
            printf( STDOUT, "%s: %s\r\n", {headers[i],value} )
		end if

	end for

	exit_code = run_hooks( HOOK_HEADERS_END )
	if exit_code then return end if

    puts( STDOUT, "\r\n" )
    puts( STDOUT, response )

	exit_code = run_hooks( HOOK_APP_END )
	if exit_code then return end if

end procedure
