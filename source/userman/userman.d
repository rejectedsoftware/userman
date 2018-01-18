/**
	Basic definitions

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.userman;

public import vibe.mail.smtp;
public import vibe.inet.url;

static import vibe.utils.validation;

import std.range : isOutputRange;

/**
	See_Also: vibe.utils.validation.validateUserName()
 */
class UserNameSettings {
	int minLength = 3;
	int maxLength = 32;
	string additionalChars = "-_";
	bool noNumberStart = false; // it's always a good idea to keep this option *disabled*
}

package bool validateUserName(R)(UserNameSettings settings, ref R error_sink, string userName)
	if (isOutputRange!(R, char))
{
	if (!settings) {
		static UserNameSettings default_settings;
		if (!default_settings) default_settings = new UserNameSettings;
		settings = default_settings;
	}

	return vibe.utils.validation.validateUserName(error_sink, userName,
            settings.minLength,
            settings.maxLength,
            settings.additionalChars,
            settings.noNumberStart);
}

/**
	Settings also used by the API
 */
class UserManCommonSettings {
	UserNameSettings userNameSettings;
	bool useUserNames = true; // use a user name or the email address for identification?
	bool requireActivation;
	string serviceName = "User database test";
	URL serviceURL = "http://www.example.com/";
	string serviceEmail = "userdb@example.com";
}

deprecated("Consistency: Use .requireActivation instead.")
@property ref inout(bool) requireAccountValidation(inout UserManCommonSettings settings)
{
	return settings.requireActivation;
}

deprecated("Consistency: Use .serviceURL instead.")
@property ref inout(URL) serviceUrl(inout UserManCommonSettings settings)
{
	return settings.serviceURL;
}

class UserManSettings : UserManCommonSettings {
	string databaseURL = "mongodb://127.0.0.1:27017/test";//*/"redis://127.0.0.1:6379/1";
	SMTPClientSettings mailSettings;

	this()
	{
		mailSettings = new SMTPClientSettings;
	}
}
