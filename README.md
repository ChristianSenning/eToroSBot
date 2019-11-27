# eToroSBot.bash

## What does it do?

eToro offers the possibility of copy trading. Unfortunately, copying is restricted to some rules. However manually copying someone is always possible. This bot monitors changes of a selected portfolio on eToro and signals changes with a telegram bot. It checks for open trades, closed trades, changed “stop loss” and changed “take profit” settings.

So far the bot is in beta state. It has not been extensively tested.

# What is missing at the moment

* extensive code testing
* Documentation
* Automatic cookie renewal
* Locking, such that it only executes once
* verbosity setting and log data

# Which are the components of the bot

1. eToroSBot.bash: the bot itself. It can be executed without argument
2. eToroSBot.conf: the configuration file of the bot. Essentially just another script in which all configuration variables are defined
3. telegram: an unchanged fork of `https://github.com/fabianonline/telegram.sh`, that sends the messages to telegram
4. asset.txt: a list of all assets on eToro. The bot used this list as lookup table to get human readable asset names. The list is generated based on this link: https://api.etorostatic.com/sapi/instrumentsmetadata/V1.1/instruments
5. cid.txt: a list of traders with their client id from eToro. The cid can be found on the page of a trader `https://www.etoro.com/people/$TRADER` when you search for `https://etoro-cdn.etorostatic.com/avatars/150X150/` the next number is the cid.
6. a cookie file: a file with cookies, that you have to generate yourself. Personally I use the Firefox addon `cookies.txt`

# Which are the dependencies of the bot

The bot has been developed under Linux and is mainly a bash script. The following packets are needed to run the bot
1. bash
2. curl
3. uuid
4. awk
5. sed

# Installation / configuration

1. Install all dependencies
2. Grab the latest `eToroSBot` from this repository and put it somewhere
3. Generate a cookie file used within the script by curl
4. Set up a telegram bot according to the description on: https://github.com/fabianonline/telegram.sh/blob/master/README.md
5. Configure `eToroSBot.conf` to your needs. At least replace all ALLCAPWORDS with your own data
6. Run the bot automatically. If you run the bot to often, eToro will ban your requests. Personally I run it every 10 minutes. For that purpose I use cron.

# Code state

Personally I would call this code early beta state. The code is for educational purposes only and has not been intensively tested. Use it on your own risc.

If you just like to see the bot in action you can use my bot, which is monitoring romantic69 portfolio. The corresponding telegram link is `t.me/eToroSbot`
Also for this telegram bot I do not take any responsibility and it is for educational purposes only. The bot runs on an old raspberry pi without proper server monitoring, UPS or similar, as it is just for my private purpose.

# Licence

eToroSBot.bash is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 3 of the License, or (at your option) any later version.
