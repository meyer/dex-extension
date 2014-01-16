#!/usr/bin/env ruby
# encoding: utf-8

require "erb"
require "uri"
require "cgi"
require "yaml"
require "webrick"
require "webrick/https"

DEX_DIR = "<%= DEX_DIR %>"
DEX_VERSION = "<%= @ext_version %>"
DEX_PORT = "<%= DEX_PORT %>"
DEX_HOSTNAME = "<%= DEX_HOSTNAME %>"

Dir.chdir DEX_DIR

# Print help
if (%w(-h --help -help) & ARGV).length > 0
	puts "usage: dexd [-hv]"
	puts "starts dex server in the foreground. kill with <Control>C"
	exit
end

# Print version number
if (%w(-v --version -version) & ARGV).length > 0
	puts "dexd #{DEX_VERSION}"
	exit
end

# String formatting methods for the console
class String
	def console_red; colorize(self, "\e[31m"); end
	def console_green; colorize(self, "\e[32m"); end
	def console_bold; colorize(self, "\e[1m"); end
	def console_underline; colorize(self, "\e[4m"); end
	def colorize(text, color_code)  "#{color_code}#{text}\e[0m" end

=begin
	# eww
	def markdown!
		# rgx = /([*_])(\1?)([^*_\s].*?[^*_\s])\2\1/ # Match bold and italic
		rgx = /\s([*_])([^*_\s].*?[^*_\s])\1\s/ # TODO: Make this not suck.
		insert(0, " ") << " " # gross
		while self =~ rgx
			# sub!(rgx, (($~[2].empty? ? "<i>%s</i>" : "<b>%s</b>") % $~[3]))
			# this works because =~ sets $~. gross.
			sub!(rgx, " <em>#{$~[2]}</em> ")
		end
		self[1...-1]
	end
=end

	def titleize
		split(/(\W)/).map(&:capitalize).join
	end
end

# Allow regexes to be concatenated
class Regexp
	def +(re)
		Regexp.new self.source + re.source
	end
end

class DexServer < WEBrick::HTTPServlet::AbstractServlet
	def do_GET(request, response)
		puts "#{Time.now}: #{request.path}"
		begin
			config = YAML::load_file("enabled.yaml")
			# Normalise config file
			config.values.map! do |arr|
				arr.map! {|v| v.to_s}.keep_if{|d| File.directory? d}.sort
			end
		rescue
			abort "Something went wrong while loading enabled.yaml"
		end

		content_types = {
			"css"  => "text/css; charset=utf-8",
			"html" => "text/html; charset=utf-8",
			"js"   => "application/javascript; charset=utf-8",
			"svg"  => "image/svg+xml; charset=utf-8",
			"png"  => "image/png",
			"edit" => "text/plain"
		}

		rgx = {
			"rsrc" => /(?<filename>[\w \-_\.@]+)\.(?<ext>png|svg|js|css)$/,
			"url" => /^\/?(?<url>[\w\-_]+\.[\w\-_\.]+)/,
			"mod" => /\/(?<mod>[\w\s\-]+)\//,
			"ext" => /\.(?<ext>css|js|html|json|edit)$/
		}

		# Info
		if request.path == "/"
			response.body = config.to_json
			return

		# Take site-specific action
		# /url.com.{css,js,html,json,edit}
		elsif (rgx["url"] + rgx["ext"]).match request.path
			url, ext = $~.captures
			response["Content-Type"] = content_types[ext]

			# TODO: Get original array in map? "h" sux.
			h = url.split(".")
			hostnames = h.each_with_index.map {|v,k| h[k..h.length].join "."}[0...-1]

			global_available = Dir.glob("global/*/").map {|s| s[0...-1]}
			global_enabled = global_available & (config["global"] || [])

			# Get all available site modules
			site_available = Dir.glob("{utilities,#{hostnames.join(",")}}/*/").map {|s| s[0...-1]}
			site_enabled = site_available & (config[url] || [])

			available_modules = global_available | site_available
			enabled_modules = global_enabled | site_enabled

			case ext
			when "html"

			# Open module folder in Finder
			# TODO: Improve, allow opening files as well: /edit/site.com/mod/file.ext
			when "edit"
				`open "#{DEX_DIR}#{url}/"`
				response.body = "Opening #{DEX_DIR}#{url}/ in Finder... Done!"
				return


				metadata = {}

				# Get all available modules
				Dir.glob("{global,utilities,*.*}/*/").each do |k|
					k = k[0...-1]
					metadata[k] = {
						"Title" => k.rpartition("/")[2].titleize,
						"Author" => nil,
						"Description" => "No description provided."
					}
				end

				# Replace lame data with nifty metadata
				Dir.glob("{global,utilities,*.*}/*/info.yaml").each do |y|
					k = y[0...-10]
					metadata[k].merge! Hash[YAML::load_file(y).each_value do |v|
						CGI::escapeHTML(v)
					end]
				end

				toggle = request.query["toggle"].to_s

				if toggle and available_modules.include?(toggle)
					if global_available.include?(toggle)
						global_enabled.push(toggle).sort! if !global_enabled.delete(toggle)
						if global_enabled.empty?
							config.delete("global")
						else
							config["global"] = global_enabled
						end
					else # This looks familiar
						site_enabled.push(toggle).sort! unless site_enabled.delete(toggle)
						if site_enabled.empty?
							config.delete(url)
						else
							config[url] = site_enabled
						end
					end

					# Write the changes
					File.open("enabled.yaml","w") do |file|
						file.write <<-file_contents
# Generated by Dex #{DEX_VERSION}
# #{Time.now.asctime}
#{YAML::dump config}
						file_contents
					end
				end

				response.body = ERB.new($site_template).result(binding)
			when "css", "js"
				body_prefix = ["/* Dex #{DEX_VERSION} at your service."]
				body = []

				unless enabled_modules.empty?
					body_prefix << "\nEnabled Modules:"
					body_prefix.push *enabled_modules.map {|e| "[+] #{e}"}
					body_prefix << "\nEnabled Files:"

					load_me = Dir.glob("{#{enabled_modules.join(",")}}/*.#{ext}")
					load_me.unshift *Dir.glob("{global,#{url}}/*.js") if ext == "js"

					load_me.each do |file|
						body_prefix << "[+] #{file}"
						body << <<-asset_file

/*# sourceURL=#{file} */
#{IO.read(file)}
/* /end #{file} */

						asset_file
					end
				end

				body_prefix << "[x] No #{ext.upcase} files to load." if body.empty?
				body_prefix << "\n*/\n"

				response.body = (body_prefix + body).join "\n"
			end

			return

		# Load a resource if it exists
		# /url.com/module/resource.{css,js,png,svg,html}
		elsif (rgx["url"] + rgx["mod"] + rgx["rsrc"]).match request.path
			url, mod, filename, ext = $~.captures

			file_path = File.join(DEX_DIR, request.path)

			if File.exist?(file_path)
				response["Content-Type"] = content_types[ext]
				response.body = IO.read(file_path)
				return
			end
		end

		response.status = 404
		response.body = "'#{request.path}' does not exist."
	end
end

ssl_cert = <<-ssl_cert
<%= File.read File.join(SERVER_SOURCE_DIR, "#{DEX_HOSTNAME}.crt") %>
ssl_cert

ssl_key = <<-ssl_key
<%= File.read File.join(SERVER_SOURCE_DIR, "#{DEX_HOSTNAME}.key") %>
ssl_key

$site_template = <<-site_template
<%= File.read File.join(SERVER_SOURCE_DIR, "site.html") %>
site_template

$site_css = <<-site_css
<%= File.read File.join(EXT_SOURCE_DIR, "popover.css") %>
site_css

server_options = {
	:Host => DEX_HOSTNAME,
	:BindAddress => "127.0.0.1",
	:Port => DEX_PORT,
	:AccessLog => [],
	:SSLEnable => true,
	:SSLVerifyClient => OpenSSL::SSL::VERIFY_NONE,
	:SSLPrivateKey => OpenSSL::PKey::RSA.new(ssl_key),
	:SSLCertificate => OpenSSL::X509::Certificate.new(ssl_cert),
	:SSLCertName => [["CN", WEBrick::Utils::getservername]],
}

server_options[:Logger] = WEBrick::Log.new("/dev/null")

server = WEBrick::HTTPServer.new(server_options)
server.mount("/", DexServer)

trap "INT" do server.shutdown end
trap "TERM" do server.shutdown end

puts "dexd #{DEX_VERSION} at your service…".console_green
server.start