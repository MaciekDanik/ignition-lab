def testScript(some_text):
	# This function will return some text
	return some_text
	
def printSecondAscii(input_date):
	seconds = system.date.getSecond(input_date)
	
	ascii_char = chr(seconds+65)
	
	return ascii_char