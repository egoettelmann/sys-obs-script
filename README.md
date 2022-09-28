System Observability Script
===========================

Pretty simple tool to help you monitor a system with bash, and receive alerts when something unexpected happens.

The tool provides following features:
 - analyze your logfiles based on provided patterns
 - compare the results with previous log files to analyze the variation
 - define thresholds that will trigger email alerts

Background
----------

Any production system should be monitored, and obviously there are a lot of tools out there that help you to do that.

But for some systems, setting up an [ELK stack](https://elastic.co), or subscribing to a cloud monitoring system, may be disproportionate.

So instead of not monitoring your system at all, and just wait on external feedback to be notified for errors, you can use this approach.

> Something is better than nothing

Installation
------------

Simply download the latest version from Github with cURL:
```sh
curl -L -o sos https://github.com/egoettelmann/sys-obs-script/raw/master/sos
```

This script can be sourced to be used within your own script.
However, if you want to use it directly (e.g. through command line, or as a cron job), make it executable:
```sh
chmod +x sos
```

Usage
-----

The easiest way to configure your monitoring rules is to use a configuration file.
By default, the script will look for a `default.cfg` file located in the same folder as the script.
To use a different file, define it through the `--config_file=*` command line argument.

More generally, any configuration defined in the configuration file can be overridden through command line.

You will see a basic sample configuration in [samples/apache/error.cfg](samples/apache/error.cfg).

To see any additional configuration options, you can run:
```sh
./sos help
```
