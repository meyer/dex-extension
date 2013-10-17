loadURL = (url) ->
	console.log "URL: #{url}"
	# TODO: Use official method to detect invalid Chrome/Safari pages
	return if ~url.indexOf('chrome://') || ~url.indexOf('//localhost') || ~url.indexOf('//127.0.0.1')

	# Strip down to hostname
	url = url.split('://')[1].split('/')[0]

	# Remove www
	url = url.replace /^www\./, ''

	dexURL = "https://localhost:3131/#{url}.html"
	document.write "<iframe src='#{dexURL}'></iframe>"

if window.safari
	loadURL safari.application.activeBrowserWindow.activeTab.url

if window.chrome
	chrome.tabs.getSelected null, (tab) ->
		loadURL tab.url