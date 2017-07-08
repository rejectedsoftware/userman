/**
	Basic definitions

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.userman;

public import vibe.mail.smtp;
public import vibe.inet.url;

/**
	See_Also: vibe.utils.validation.validateUserName()
 */
struct UserNameSettings {
	int minLength = 3;
	int maxLength = 32;
	string additionalChars = "-_";
	bool noNumberStart = false; // it's always a good idea to *not* able this option
}

/**
	Settings also used by the API
 */
struct UserManCommonSettings {
	UserNameSettings userNameSettings;
	bool useUserNames = true; // use a user name or the email address for identification?
	bool requireAccountValidation;
	deprecated("Consistency: Use .requireAccountValidation instead.") alias requireActivation = requireAccountValidation;
	string serviceName = "User database test";
	URL serviceURL = "http://www.example.com/";
	string serviceEmail = "userdb@example.com";
}

class UserManSettings {
	UserManCommonSettings common;
	alias common this;

	string databaseURL = "mongodb://127.0.0.1:27017/test";//*/"redis://127.0.0.1:6379/1";
	SMTPClientSettings mailSettings;

	this()
	{
		mailSettings = new SMTPClientSettings;
	}

	deprecated("Consistency: Use .serviceURL instead.") @property {
		URL serviceUrl() {
			return this.common.serviceURL;
		}
		void serviceUrl(URL value) {
			this.common.serviceURL = value;
		}
	}
	
}
