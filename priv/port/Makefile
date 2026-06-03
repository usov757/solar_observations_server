ASI_SDK = ../../lib/asi_sdk
CC      = gcc
CFLAGS  = -O2 -Wall
INC     = -I$(ASI_SDK)/include
LIBS = -L$(ASI_SDK)/lib/x64 -Wl,-rpath,$(ASI_SDK)/lib/x64 -lASICamera2 -lpthread -lusb-1.0

asi_port: asi_port.c
	$(CC) $(CFLAGS) $(INC) -o asi_port asi_port.c $(LIBS)
	chmod +x asi_port