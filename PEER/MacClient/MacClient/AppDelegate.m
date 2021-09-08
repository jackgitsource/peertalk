//
//  AppDelegate.m
//  MacClient
//
//  Created by paxhz on 2021/9/8.
//

#import "AppDelegate.h"
#import "PTUSBHub.h"
#import "PTChannel.h"
#import "PTExampleProtocol.h"
static const NSTimeInterval PTAppReconnectDelay = 1.0;
@interface AppDelegate ()
{
  // If the remote connection is over USB transport...
  NSNumber *connectingToDeviceID_;
  NSNumber *connectedDeviceID_;
  NSDictionary *connectedDeviceProperties_;
  NSDictionary *remoteDeviceInfo_;
  dispatch_queue_t notConnectedQueue_;
  BOOL notConnectedQueueSuspended_;
  PTChannel *connectedChannel_;
  NSDictionary *consoleTextAttributes_;
  NSDictionary *consoleStatusTextAttributes_;
  NSMutableDictionary *pings_;
}

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Start listening for device attached/detached notifications
    [self startListeningForDevices];
    
    // Start trying to connect to local IPv4 port (defined in PTExampleProtocol.h)
    [self enqueueConnectToLocalIPv4Port];
    
    // Put a little message in the UI
    //[self presentMessage:@"Ready for action — connecting at will." isStatus:YES];
    
    // Start pinging
    [self ping];
}


- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

// 开始监听设备的连接与断开
- (void)startListeningForDevices {
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  
  [nc addObserverForName:PTUSBDeviceDidAttachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
    NSNumber *deviceID = [note.userInfo objectForKey:PTUSBHubNotificationKeyDeviceID];
    //NSLog(@"PTUSBDeviceDidAttachNotification: %@", note.userInfo);
    NSLog(@"PTUSBDeviceDidAttachNotification: %@", deviceID);

    dispatch_async(self->notConnectedQueue_, ^{
      if (!self->connectingToDeviceID_ || ![deviceID isEqualToNumber:self->connectingToDeviceID_]) {
        [self disconnectFromCurrentChannel];
                self->connectingToDeviceID_ = deviceID;
                self->connectedDeviceProperties_ = [note.userInfo objectForKey:PTUSBHubNotificationKeyProperties];
        [self enqueueConnectToUSBDevice];
      }
    });
  }];
  
  [nc addObserverForName:PTUSBDeviceDidDetachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
    NSNumber *deviceID = [note.userInfo objectForKey:PTUSBHubNotificationKeyDeviceID];
    //NSLog(@"PTUSBDeviceDidDetachNotification: %@", note.userInfo);
    NSLog(@"PTUSBDeviceDidDetachNotification: %@", deviceID);
    
    if ([self->connectingToDeviceID_ isEqualToNumber:deviceID]) {
            self->connectedDeviceProperties_ = nil;
            self->connectingToDeviceID_ = nil;
      if (self->connectedChannel_) {
        [self->connectedChannel_ close];
      }
    }
  }];
}

- (void)disconnectFromCurrentChannel {
  if (connectedDeviceID_ && connectedChannel_) {
    [connectedChannel_ close];
    self.connectedChannel = nil;
  }
}

- (void)setConnectedChannel:(PTChannel*)connectedChannel {
  connectedChannel_ = connectedChannel;
  
  // Toggle the notConnectedQueue_ depending on if we are connected or not
  if (!connectedChannel_ && notConnectedQueueSuspended_) {
    dispatch_resume(notConnectedQueue_);
    notConnectedQueueSuspended_ = NO;
  } else if (connectedChannel_ && !notConnectedQueueSuspended_) {
    dispatch_suspend(notConnectedQueue_);
    notConnectedQueueSuspended_ = YES;
  }
  
  if (!connectedChannel_ && connectingToDeviceID_) {
    [self enqueueConnectToUSBDevice];
  }
}

- (void)enqueueConnectToUSBDevice {
  dispatch_async(notConnectedQueue_, ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      [self connectToUSBDevice];
    });
  });
}

- (void)connectToUSBDevice {
  PTChannel *channel = [PTChannel channelWithDelegate:self];
  channel.userInfo = connectingToDeviceID_;
  channel.delegate = self;
  
  [channel connectToPort:PTExampleProtocolIPv4PortNumber overUSBHub:PTUSBHub.sharedHub deviceID:connectingToDeviceID_ callback:^(NSError *error) {
    if (error) {
      if (error.domain == PTUSBHubErrorDomain && error.code == PTUSBHubErrorConnectionRefused) {
        NSLog(@"Failed to connect to device #%@: %@", channel.userInfo, error);
      } else {
        NSLog(@"Failed to connect to device #%@: %@", channel.userInfo, error);
      }
      if (channel.userInfo == self->connectingToDeviceID_) {
        [self performSelector:@selector(enqueueConnectToUSBDevice) withObject:nil afterDelay:PTAppReconnectDelay];
      }
    } else {
            self->connectedDeviceID_ = self->connectingToDeviceID_;
      self.connectedChannel = channel;
    }
  }];
}

#pragma mark -

- (void)enqueueConnectToLocalIPv4Port {
  dispatch_async(notConnectedQueue_, ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      [self connectToLocalIPv4Port];
    });
  });
}


- (void)connectToLocalIPv4Port {
  PTChannel *channel = [PTChannel channelWithDelegate:self];
  channel.userInfo = [NSString stringWithFormat:@"127.0.0.1:%d", PTExampleProtocolIPv4PortNumber];
  [channel connectToPort:PTExampleProtocolIPv4PortNumber IPv4Address:INADDR_LOOPBACK callback:^(NSError *error, PTAddress *address) {
    if (error) {
      if (error.domain == NSPOSIXErrorDomain && (error.code == ECONNREFUSED || error.code == ETIMEDOUT)) {
        // this is an expected state
      } else {
        NSLog(@"Failed to connect to 127.0.0.1:%d: %@", PTExampleProtocolIPv4PortNumber, error);
      }
    } else {
      [self disconnectFromCurrentChannel];
      self.connectedChannel = channel;
      channel.userInfo = address;
      NSLog(@"Connected to %@", address);
    }
    [self performSelector:@selector(enqueueConnectToLocalIPv4Port) withObject:nil afterDelay:PTAppReconnectDelay];
  }];
}

#pragma mark -

- (void)ping {
  if (connectedChannel_) {
    if (!pings_) {
      pings_ = [NSMutableDictionary dictionary];
    }
    uint32_t tagno = [connectedChannel_.protocol newTag];
    NSNumber *tag = [NSNumber numberWithUnsignedInt:tagno];
    NSMutableDictionary *pingInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:[NSDate date], @"date created", nil];
    [pings_ setObject:pingInfo forKey:tag];
    [connectedChannel_ sendFrameOfType:PTExampleFrameTypePing tag:tagno withPayload:nil callback:^(NSError *error) {
      [self performSelector:@selector(ping) withObject:nil afterDelay:1.0];
      [pingInfo setObject:[NSDate date] forKey:@"date sent"];
      if (error) {
        [self->pings_ removeObjectForKey:tag];
      }
    }];
  } else {
    [self performSelector:@selector(ping) withObject:nil afterDelay:1.0];
  }
}

@end
