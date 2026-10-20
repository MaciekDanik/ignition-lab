def fullPromotionMarker():
	return "FULL_PROMOTION_TEST_20261020"
	
def printSecondAscii(input_date):
	seconds = system.date.getSecond(input_date)
	
	ascii_char = chr(seconds+65)
	
	return ascii_char