/**
 * Concepts shared between HTTP clients and servers.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Stéphan Kochen <stephan@kochen.nl>
 *   Vladimir Panteleev <ae@cy.md>
 *   Simon Arlott
 */

module ae.net.http.common;

import core.time;

import std.algorithm;
import std.array;
import std.base64;
import std.string;
import std.conv;
import std.ascii;
import std.exception;
import std.datetime;
import std.typecons : tuple;

import ae.net.ietf.headers;
import ae.sys.data;
import ae.sys.dataset;
import ae.utils.array : amap, afilter, auniq, asort, asBytes, as;
import ae.utils.text;
import ae.utils.time;

version (ae_with_zlib) // Explicit override
	enum haveZlib = true;
else
version (ae_without_zlib) // Explicit override
	enum haveZlib = false;
else
version (Have_ae) // Building with Dub
{
	version (Have_ae_zlib) // Using ae:zlib
		enum haveZlib = true;
	else
		enum haveZlib = false;
}
else // Not building with Dub
	enum haveZlib = true; // Pull in zlib by default

static if (haveZlib)
{
	import zlib = ae.utils.zlib;
	import gzip = ae.utils.gzip;
}

/// Base HTTP message class
private abstract class HttpMessage
{
public:
	string protocol = "http";
	string protocolVersion = "1.0";
	Headers headers;
	DataVec data;
	SysTime creationTime;

	this()
	{
		creationTime = Clock.currTime();
	}

	@property Duration age()
	{
		return Clock.currTime() - creationTime;
	}

	/// For `dup`.
	protected void copyTo(typeof(this) other)
	{
		other.protocol = protocol;
		other.protocolVersion = protocolVersion;
		other.headers = headers.dup;
		other.data = data.dup;
		other.creationTime = creationTime;
	}
}

// TODO: Separate this from an URL type

/// HTTP request class
class HttpRequest : HttpMessage
{
public:
	/// HTTP method, e.g., "GET".
	string method = "GET";

	/// If this request is going through a HTTP proxy server, this
	/// should be set to its address.
	string proxy;

	this()
	{
	} ///

	this(string url)
	{
		this.resource = url;
	} ///

	/// For `dup`.
	protected void copyTo(typeof(this) other)
	{
		super.copyTo(other);
		other.method = method;
		other.proxy = proxy;
		other._resource = _resource;
		other._port = _port;
	}
	alias copyTo = typeof(super).copyTo;

	final typeof(this) dup()
	{
		auto result = new typeof(this);
		copyTo(result);
		return result;
	} ///

	/// Resource part of URL (everything after the hostname)
	@property string resource() const pure nothrow @nogc
	{
		return _resource;
	}

	/// Set the resource part of the URL, or the entire URL.
	/// Setting the resource to a full URL will fill in the Host header, as well.
	@property void resource(string value) pure
	{
		_resource = value;

		// applies to both Client/Server as some clients put a full URL in the GET line instead of using a "Host" header
		string protocol;
		if (_resource.asciiStartsWith("http://"))
			protocol = "http";
		else
		if (_resource.asciiStartsWith("https://"))
			protocol = "https";

		if (protocol)
		{
			this.protocol = protocol;

			value = value[protocol.length+3..$];
			auto pathstart = value.indexOf('/');
			string _host;
			if (pathstart == -1)
			{
				_host = value;
				_resource = "/";
			}
			else
			{
				_host = value[0..pathstart];
				_resource = value[pathstart..$];
			}

			auto authEnd = _host.indexOf('@');
			if (authEnd != -1)
			{
				// Assume HTTP Basic auth
				import ae.utils.array : asBytes;
				headers["Authorization"] = "Basic " ~ Base64.encode(_host[0 .. authEnd].asBytes).assumeUnique;
				_host = _host[authEnd + 1 .. $];
			}

			auto portstart = _host.indexOf(':');
			if (portstart != -1)
			{
				port = to!ushort(_host[portstart+1..$]);
				_host = _host[0..portstart];
			}
			host = _host;
		}
	}

	/// The hostname, without the port number
	@property string host() const pure nothrow @nogc
	{
		string _host = headers.get("Host", null);
		// auto colon = _host.lastIndexOf(':'); // https://issues.dlang.org/show_bug.cgi?id=24008
		sizediff_t colon = -1; foreach_reverse (i, c; _host) if (c == ':') { colon = i; break; }
		return colon < 0 ? _host : _host[0 .. colon];
	}

	/// Sets the hostname (and the `"Host"` header).
	/// Must not include a port number.
	/// Does not change the previously-set port number.
	@property void host(string _host) pure
	{
		auto _port = this.port;
		headers["Host"] = _port==protocolDefaultPort ? _host : _host ~ ":" ~ text(_port);
	}

	/// Retrieves the default port number for the currently set `protocol`.
	@property ushort protocolDefaultPort() const pure
	{
		switch (protocol)
		{
			case "http":
				return 80;
			case "https":
				return 443;
			default:
				throw new Exception("Unknown protocol: " ~ protocol);
		}
	}

	/// Port number, from `"Host"` header.
	/// Defaults to `protocolDefaultPort`.
	@property ushort port() const pure
	{
		if ("Host" in headers)
		{
			string _host = headers["Host"];
			auto colon = _host.lastIndexOf(":");
			return colon<0 ? protocolDefaultPort : to!ushort(_host[colon+1..$]);
		}
		else
			return _port ? _port : protocolDefaultPort;
	}

	/// Sets the port number.
	/// If it is equal to `protocolDefaultPort`, then it is not
	/// included in the `"Host"` header.
	@property void port(ushort _port) pure
	{
		if ("Host" in headers)
		{
			if (_port == protocolDefaultPort)
				headers["Host"] = this.host;
			else
				headers["Host"] = this.host ~ ":" ~ text(_port);
		}
		else
			this._port = _port;
	}

	/// Path part of request (until the `'?'`).
	@property string path() const pure nothrow @nogc
	{
		auto p = resource.indexOf('?');
		if (p >= 0)
			return resource[0..p];
		else
			return resource;
	}

	/// Query string part of request (atfer the `'?'`).
	@property string queryString() const pure nothrow @nogc
	{
		auto p = resource.indexOf('?');
		if (p >= 0)
			return resource[p+1..$];
		else
			return null;
	}

	/// ditto
	@property void queryString(string value) pure
	{
		auto p = resource.indexOf('?');
		if (p >= 0)
			resource = resource[0..p];
		if (value)
			resource = resource ~ '?' ~ value;
	}

	/// The query string parameters.
	@property UrlParameters urlParameters()
	{
		return decodeUrlParameters(queryString);
	}

	/// ditto
	@property void urlParameters(UrlParameters parameters)
	{
		queryString = encodeUrlParameters(parameters);
	}

	/// URL without resource (protocol, host and port).
	@property string root()
	{
		return protocol ~ "://" ~ host ~ (port==protocolDefaultPort ? null : ":" ~ to!string(port));
	}

	/// Full URL.
	@property string url()
	{
		return root ~ resource;
	}

	/// Full URL without query parameters or fragment.
	@property string baseURL()
	{
		return root ~ resource.findSplit("?")[0];
	}

	/// The hostname part of the proxy address, if any.
	@property string proxyHost()
	{
		auto portstart = proxy.indexOf(':');
		if (portstart != -1)
			return proxy[0..portstart];
		return proxy;
	}

	/// The port number of the proxy address if it specified, otherwise `80`.
	@property ushort proxyPort()
	{
		auto portstart = proxy.indexOf(':');
		if (portstart != -1)
			return to!ushort(proxy[portstart+1..$]);
		return 80;
	}

	/// Parse the first line in a HTTP request ("METHOD /resource HTTP/1.x").
	void parseRequestLine(string reqLine)
	{
		enforce(reqLine.length > 10, "Request line too short");
		auto methodEnd = reqLine.indexOf(' ');
		enforce(methodEnd > 0, "Malformed request line");
		method = reqLine[0 .. methodEnd];
		reqLine = reqLine[methodEnd + 1 .. reqLine.length];

		auto resourceEnd = reqLine.lastIndexOf(' ');
		enforce(resourceEnd > 0, "Malformed request line");
		resource = reqLine[0 .. resourceEnd];

		string protocol = reqLine[resourceEnd+1..$];
		enforce(protocol.startsWith("HTTP/"));
		protocolVersion = protocol[5..$];
	}

	/// Decodes submitted form data, and returns an AA of values.
	UrlParameters decodePostData()
	{
		auto contentType = headers.get("Content-Type", "").decodeTokenHeader;

		switch (contentType.value)
		{
			case "application/x-www-form-urlencoded":
				return decodeUrlParameters(data.joinToGC().as!string);
			case "multipart/form-data":
				return decodeMultipart(data.joinData(), contentType.properties.get("boundary", null))
					.map!(part => tuple(
						part.headers.get("Content-Disposition", null).decodeTokenHeader.properties.get("name", null),
						part.data.asDataOf!char.toGC().assumeUnique,
					))
					.UrlParameters;
			case "":
				throw new Exception("No Content-Type");
			default:
				throw new Exception("Unknown Content-Type: " ~ contentType.value);
		}
	}

	/// Get list of hosts as specified in headers (e.g. X-Forwarded-For).
	/// First item in returned array is the node furthest away.
	/// Duplicates are removed.
	/// Specify socket remote address in remoteHost to add it to the list.
	deprecated("Insecure, use HttpServer.remoteIPHeader")
	string[] remoteHosts(string remoteHost = null)
	{
		return
			(headers.get("X-Forwarded-For", null).split(",").amap!(std.string.strip)() ~
			 headers.get("X-Forwarded-Host", null) ~
			 remoteHost)
			.afilter!`a && a != "unknown"`()
			.auniq();
	}

	deprecated unittest
	{
		auto req = new HttpRequest();
		assert(req.remoteHosts() == []);
		assert(req.remoteHosts("3.3.3.3") == ["3.3.3.3"]);

		req.headers["X-Forwarded-For"] = "1.1.1.1, 2.2.2.2";
		req.headers["X-Forwarded-Host"] = "2.2.2.2";
		assert(req.remoteHosts("3.3.3.3") == ["1.1.1.1", "2.2.2.2", "3.3.3.3"]);
	}

	/// Basic cookie parsing
	string[string] getCookies()
	{
		string[string] cookies;
		foreach (segment; headers.get("Cookie", null).split(";"))
		{
			segment = segment.strip();
			auto p = segment.indexOf('=');
			if (p > 0)
				cookies[segment[0..p]] = segment[p+1..$];
		}
		return cookies;
	}

private:
	string _resource;
	ushort _port = 0; // used only when no "Host" in headers; otherwise, taken from there
}

/// HTTP response status codes
enum HttpStatusCode : ushort
{
	None                         =   0,  ///

	Continue                     = 100,  ///
	SwitchingProtocols           = 101,  ///

	OK                           = 200,  ///
	Created                      = 201,  ///
	Accepted                     = 202,  ///
	NonAuthoritativeInformation  = 203,  ///
	NoContent                    = 204,  ///
	ResetContent                 = 205,  ///
	PartialContent               = 206,  ///

	MultipleChoices              = 300,  ///
	MovedPermanently             = 301,  ///
	Found                        = 302,  ///
	SeeOther                     = 303,  ///
	NotModified                  = 304,  ///
	UseProxy                     = 305,  ///
	//(Unused)                   = 306,  ///
	TemporaryRedirect            = 307,  ///

	BadRequest                   = 400,  ///
	Unauthorized                 = 401,  ///
	PaymentRequired              = 402,  ///
	Forbidden                    = 403,  ///
	NotFound                     = 404,  ///
	MethodNotAllowed             = 405,  ///
	NotAcceptable                = 406,  ///
	ProxyAuthenticationRequired  = 407,  ///
	RequestTimeout               = 408,  ///
	Conflict                     = 409,  ///
	Gone                         = 410,  ///
	LengthRequired               = 411,  ///
	PreconditionFailed           = 412,  ///
	RequestEntityTooLarge        = 413,  ///
	RequestUriTooLong            = 414,  ///
	UnsupportedMediaType         = 415,  ///
	RequestedRangeNotSatisfiable = 416,  ///
	ExpectationFailed            = 417,  ///
	MisdirectedRequest           = 421,  ///
	UnprocessableContent         = 422,  ///
	Locked                       = 423,  ///
	FailedDependency             = 424,  ///
	TooEarly                     = 425,  ///
	UpgradeRequired              = 426,  ///
	PreconditionRequired         = 428,  ///
	TooManyRequests              = 429,  ///
	RequestHeaderFieldsTooLarge  = 431,  ///
	UnavailableForLegalReasons   = 451,  ///

	InternalServerError          = 500,  ///
	NotImplemented               = 501,  ///
	BadGateway                   = 502,  ///
	ServiceUnavailable           = 503,  ///
	GatewayTimeout               = 504,  ///
	HttpVersionNotSupported      = 505,  ///
}

/// HTTP reply class
class HttpResponse : HttpMessage
{
public:
	HttpStatusCode status; /// HTTP status code
	string statusMessage; /// HTTP status message, if one was supplied

	/// What Zlib compression level to use when compressing the reply.
	/// Set to a negative value to disable compression.
	int compressionLevel = 1;

	/// Returns the message corresponding to the given `HttpStatusCode`,
	/// or `null` if the code is unknown.
	static string getStatusMessage(HttpStatusCode code)
	{
		switch(code)
		{
			case 100: return "Continue";
			case 101: return "Switching Protocols";

			case 200: return "OK";
			case 201: return "Created";
			case 202: return "Accepted";
			case 203: return "Non-Authoritative Information";
			case 204: return "No Content";
			case 205: return "Reset Content";
			case 206: return "Partial Content";
			case 300: return "Multiple Choices";
			case 301: return "Moved Permanently";
			case 302: return "Found";
			case 303: return "See Other";
			case 304: return "Not Modified";
			case 305: return "Use Proxy";
			case 306: return "(Unused)";
			case 307: return "Temporary Redirect";

			case 400: return "Bad Request";
			case 401: return "Unauthorized";
			case 402: return "Payment Required";
			case 403: return "Forbidden";
			case 404: return "Not Found";
			case 405: return "Method Not Allowed";
			case 406: return "Not Acceptable";
			case 407: return "Proxy Authentication Required";
			case 408: return "Request Timeout";
			case 409: return "Conflict";
			case 410: return "Gone";
			case 411: return "Length Required";
			case 412: return "Precondition Failed";
			case 413: return "Request Entity Too Large";
			case 414: return "Request-URI Too Long";
			case 415: return "Unsupported Media Type";
			case 416: return "Requested Range Not Satisfiable";
			case 417: return "Expectation Failed";

			case 500: return "Internal Server Error";
			case 501: return "Not Implemented";
			case 502: return "Bad Gateway";
			case 503: return "Service Unavailable";
			case 504: return "Gateway Timeout";
			case 505: return "HTTP Version Not Supported";
			default: return null;
		}
	}

	/// Set the response status code and message
	void setStatus(HttpStatusCode code)
	{
		status = code;
		statusMessage = getStatusMessage(code);
	}

	/// Initializes this `HttpResponse` with the given `statusLine`.
	final void parseStatusLine(string statusLine)
	{
		auto versionEnd = statusLine.indexOf(' ');
		if (versionEnd == -1)
			throw new Exception("Malformed status line");
		protocolVersion = statusLine[0..versionEnd];
		statusLine = statusLine[versionEnd+1..statusLine.length];

		auto statusEnd = statusLine.indexOf(' ');
		string statusCode;
		if (statusEnd >= 0)
		{
			statusCode = statusLine[0 .. statusEnd];
			statusMessage = statusLine[statusEnd+1..statusLine.length];
		}
		else
		{
			statusCode = statusLine;
			statusMessage = null;
		}
		status = cast(HttpStatusCode)to!ushort(statusCode);
	}

	/// If the data is compressed, return the decompressed data
	// this is not a property on purpose - to avoid using it multiple times as it will unpack the data on every access
	// TODO: there is no reason for above limitation
	Data getContent()
	{
		if ("Content-Encoding" in headers && headers["Content-Encoding"]=="deflate")
		{
			static if (haveZlib)
				return zlib.uncompress(data[]).joinData();
			else
				throw new Exception("Built without zlib - can't decompress \"Content-Encoding: deflate\" content");
		}
		if ("Content-Encoding" in headers && headers["Content-Encoding"]=="gzip")
		{
			static if (haveZlib)
				return gzip.uncompress(data[]).joinData();
			else
				throw new Exception("Built without zlib - can't decompress \"Content-Encoding: gzip\" content");
		}
		return data.joinData();
	}

	static if (haveZlib)
	protected void compressWithDeflate()
	{
		assert(compressionLevel >= 0);
		data = zlib.compress(data[], zlib.ZlibOptions(compressionLevel));
	}

	static if (haveZlib)
	protected void compressWithGzip()
	{
		assert(compressionLevel >= 0);
		data = gzip.compress(data[], zlib.ZlibOptions(compressionLevel));
	}

	/// Called by the server to compress content, if possible/appropriate
	final package void optimizeData(ref const Headers requestHeaders)
	{
		if (compressionLevel < 0)
			return;
		auto acceptEncoding = requestHeaders.get("Accept-Encoding", null);
		if (acceptEncoding && "Content-Encoding" !in headers && "Content-Length" !in headers)
		{
			auto contentType = headers.get("Content-Type", null);
			if (contentType.startsWith("text/")
			 || contentType == "application/json"
			 || contentType == "image/vnd.microsoft.icon"
			 || contentType == "image/svg+xml")
			{
				auto supported = parseItemList(acceptEncoding) ~ ["*"];
				foreach (method; supported)
					switch (method)
					{
						static if (haveZlib)
						{
							case "deflate":
								headers["Content-Encoding"] = method;
								headers.add("Vary", "Accept-Encoding");
								compressWithDeflate();
								return;
							case "gzip":
								headers["Content-Encoding"] = method;
								headers.add("Vary", "Accept-Encoding");
								compressWithGzip();
								return;
						}
						case "*":
							if("Content-Encoding" in headers)
								headers.remove("Content-Encoding");
							return;
						default:
							break;
					}
				assert(0);
			}
		}
	}

	/// Called by the server to apply range request.
	final package void sliceData(ref const Headers requestHeaders)
	{
		if (status == HttpStatusCode.OK &&
			"Content-Range" !in headers &&
			"Accept-Ranges" !in headers &&
			"Content-Length" !in headers)
		{
			if ("If-Modified-Since" in requestHeaders &&
				"Last-Modified" in headers &&
				headers["Last-Modified"].parseTime!(TimeFormats.HTTP) <= requestHeaders["If-Modified-Since"].parseTime!(TimeFormats.HTTP))
			{
				setStatus(HttpStatusCode.NotModified);
				data = null;
				return;
			}

			headers["Accept-Ranges"] = "bytes";
			auto prange = "Range" in requestHeaders;
			if (prange && (*prange).startsWith("bytes="))
			{
				auto ranges = (*prange)[6..$].split(",")[0].split("-").map!(s => s.length ? s.to!size_t : size_t.max)().array();
				enforce(ranges.length == 2, "Bad range request");
				ranges[1]++;
				auto datum = this.data.bytes;
				auto datumLength = datum.length;
				if (ranges[1] == size_t.min) // was not specified (size_t.max overflowed into 0)
					ranges[1] = datumLength;
				if (ranges[0] >= datumLength || ranges[0] >= ranges[1] || ranges[1] > datumLength)
				{
					//writeError(HttpStatusCode.RequestedRangeNotSatisfiable);
					setStatus(HttpStatusCode.RequestedRangeNotSatisfiable);
					data = DataVec(Data(statusMessage.asBytes));
					return;
				}
				else
				{
					setStatus(HttpStatusCode.PartialContent);
					this.data = datum[ranges[0]..ranges[1]];
					headers["Content-Range"] = "bytes %d-%d/%d".format(ranges[0], ranges[0] + this.data.bytes.length - 1, datumLength);
				}
			}
		}
	}

	protected void copyTo(typeof(this) other)
	{
		other.status = status;
		other.statusMessage = statusMessage;
		other.compressionLevel = compressionLevel;
	}
	alias copyTo = typeof(super).copyTo;

	final typeof(this) dup()
	{
		auto result = new typeof(this);
		copyTo(result);
		return result;
	} ///
}

/// Sets headers to request clients to not cache a response.
void disableCache(ref Headers headers)
{
	headers["Expires"] = "Mon, 26 Jul 1997 05:00:00 GMT";  // disable IE caching
	//headers["Last-Modified"] = "" . gmdate( "D, d M Y H:i:s" ) . " GMT";
	headers["Cache-Control"] = "no-cache, must-revalidate";
	headers["Pragma"] = "no-cache";
}

/// Sets headers to request clients to cache a response indefinitely.
void cacheForever(ref Headers headers)
{
	headers["Expires"] = httpTime(Clock.currTime().add!"years"(1));
	headers["Cache-Control"] = "public, max-age=31536000";
}

/// Formats a timestamp in the format used by HTTP (RFC 2822).
string httpTime(SysTime time)
{
	time.timezone = UTC();
	return time.formatTime!(TimeFormats.HTTP)();
}

import std.algorithm : sort;

/// Parses a list in the format of "a, b, c;q=0.5, d" and returns
/// an array of items sorted by "q" (["a", "b", "d", "c"])
string[] parseItemList(string s)
{
	static struct Item
	{
		float q = 1.0;
		string str;

		this(string s)
		{
			auto params = s.split(";");
			if (!params.length) return;
			str = params[0];
			foreach (param; params[1..$])
				if (param.startsWith("q="))
					q = to!float(param[2..$]);
		}
	}

	return s
		.split(",")
		.amap!(a => Item(strip(a)))()
		.asort!`a.q > b.q`()
		.amap!`a.str`();
}

unittest
{
	assert(parseItemList("a, b, c;q=0.5, d") == ["a", "b", "d", "c"]);
}

// TODO: optimize / move to HtmlWriter
deprecated("Use ae.utils.xml.entities")
string httpEscape(string str)
{
	string result;
	foreach(c;str)
		switch(c)
		{
			case '<':
				result ~= "&lt;";
				break;
			case '>':
				result ~= "&gt;";
				break;
			case '&':
				result ~= "&amp;";
				break;
			case '\xDF':  // the beta-like symbol
				result ~= "&szlig;";
				break;
			default:
				result ~= [c];
		}
	return result;
}

public import ae.net.ietf.url : UrlParameters, encodeUrlParameter, encodeUrlParameters, decodeUrlParameter, decodeUrlParameters;

/// Represents a part from a multipart/* message.
struct MultipartPart
{
	/// The part's individual headers.
	Headers headers;

	/// The part's contents.
	Data data;
}

/// Encode a multipart body with the given parts and boundary.
Data encodeMultipart(MultipartPart[] parts, string boundary)
{
	TData!char data;
	foreach (ref part; parts)
	{
		data ~= "--" ~ boundary ~ "\r\n";
		foreach (name, value; part.headers)
			data ~= name ~ ": " ~ value ~ "\r\n";
		data ~= "\r\n";
		assert(part.data.asDataOf!char.indexOf(boundary) < 0);
		data ~= part.data.asDataOf!char;
		data ~= "\r\n";
	}
	data ~= "--" ~ boundary ~ "--\r\n";
	return data.asDataOf!ubyte;
}

/// Decode a multipart body using the given boundary.
MultipartPart[] decodeMultipart(Data data, string boundary)
{
	MultipartPart[] result;
	data.asDataOf!char.enter((scope s) {
		auto term = "\r\n--" ~ boundary ~ "--\r\n";
		enforce(s.endsWith(term), "Bad multipart terminator");
		s = s[0..$-term.length];
		auto delim = "--" ~ boundary ~ "\r\n";
		enforce(s.skipOver(delim), "Bad multipart start");
		delim = "\r\n" ~ delim;
		auto parts = s.split(delim);
		foreach (part; parts)
		{
			auto segs = part.findSplit("\r\n\r\n");
			enforce(segs[1], "Can't find headers in multipart part");
			MultipartPart p;
			foreach (line; segs[0].split("\r\n"))
			{
				auto hparts = line.findSplit(":");
				p.headers[hparts[0].strip.idup] = hparts[2].strip.idup;
			}
			p.data = Data(segs[2].asBytes);
			result ~= p;
		}
	});
	return result;
}

unittest
{
	auto parts = [
		MultipartPart(Headers(["Foo" : "bar"]), Data.init),
		MultipartPart(Headers(["Baz" : "quux", "Frob" : "xyzzy"]), Data("Content goes here\xFF".asBytes)),
	];
	auto boundary = "abcde";
	auto parts2 = parts.encodeMultipart(boundary).decodeMultipart(boundary);
	assert(parts2.length == parts.length);
	foreach (p; 0..parts.length)
	{
		assert(parts[p].headers == parts2[p].headers);
		assert(parts[p].data.unsafeContents == parts2[p].data.unsafeContents);
	}
}

private bool asciiStartsWith(string s, string prefix) pure nothrow @nogc
{
	if (s.length < prefix.length)
		return false;
	import std.ascii;
	foreach (i, c; prefix)
		if (toLower(c) != toLower(s[i]))
			return false;
	return true;
}
