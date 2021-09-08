//
//  ViewController.m
//  IOSClient
//
//  Created by paxhz on 2021/9/8.
//

#import "ViewController.h"
#import "PTChannel.h"
#import "PTExampleProtocol.h"

@interface ViewController ()<PTChannelDelegate>
{
  __weak PTChannel *serverChannel_;
  __weak PTChannel *peerChannel_;
}
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    // 创建 channel
    PTChannel *channel = [PTChannel channelWithDelegate:self];
    // 监听指定端口,PTExampleProtocolIPv4PortNumber自定义端口号
    [channel listenOnPort:2345 IPv4Address:INADDR_LOOPBACK callback:^(NSError *error) {
        if (error) { // 创建监听失败
            NSLog(@"创建监听失败");
        } else { // 创建监听成功
            NSLog(@"创建监听成功");
            self->serverChannel_ = channel;
        }
    }];
}

#pragma mark - PTChannelDelegate

// Invoked to accept an incoming frame on a channel. Reply NO ignore the
// incoming frame. If not implemented by the delegate, all frames are accepted.
- (BOOL)ioFrameChannel:(PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
  if (channel != peerChannel_) {
    // A previous channel that has been canceled but not yet ended. Ignore.
    return NO;
  } else if (type != PTExampleFrameTypeTextMessage && type != PTExampleFrameTypePing) {
    NSLog(@"Unexpected frame of type %u", type);
    [channel close];
    return NO;
  } else {
    return YES;
  }
}

// Invoked when a new frame has arrived on a channel.
- (void)ioFrameChannel:(PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(NSData *)payload {
  if (type == PTExampleFrameTypeTextMessage) {
    PTExampleTextFrame *textFrame = (PTExampleTextFrame*)payload.bytes;
    textFrame->length = ntohl(textFrame->length);
    NSString *message = [[NSString alloc] initWithBytes:textFrame->utf8text length:textFrame->length encoding:NSUTF8StringEncoding];
    [self appendOutputMessage:[NSString stringWithFormat:@"[%@]: %@", channel.userInfo, message]];
  } else if (type == PTExampleFrameTypePing && peerChannel_) {
    [peerChannel_ sendFrameOfType:PTExampleFrameTypePong tag:tag withPayload:nil callback:nil];
  }
}

// Invoked when the channel closed. If it closed because of an error, *error* is
// a non-nil NSError object.
- (void)ioFrameChannel:(PTChannel*)channel didEndWithError:(NSError*)error {
  if (error) {
    [self appendOutputMessage:[NSString stringWithFormat:@"%@ ended with error: %@", channel, error]];
  } else {
    [self appendOutputMessage:[NSString stringWithFormat:@"Disconnected from %@", channel.userInfo]];
  }
}

// For listening channels, this method is invoked when a new connection has been
// accepted.
- (void)ioFrameChannel:(PTChannel*)channel didAcceptConnection:(PTChannel*)otherChannel fromAddress:(PTAddress*)address {
  // Cancel any other connection. We are FIFO, so the last connection
  // established will cancel any previous connection and "take its place".
  if (peerChannel_) {
    [peerChannel_ cancel];
  }
  
  // Weak pointer to current connection. Connection objects live by themselves
  // (owned by its parent dispatch queue) until they are closed.
  peerChannel_ = otherChannel;
  peerChannel_.userInfo = address;
  [self appendOutputMessage:[NSString stringWithFormat:@"Connected to %@", address]];
  
  // Send some information about ourselves to the other end
  [self sendDeviceInfo];
}

- (void)appendOutputMessage:(NSString*)message {
    NSLog(@">> %@", message);
}

- (void)sendDeviceInfo {
  if (!peerChannel_) {
    return;
  }
  
  NSLog(@"Sending device info over %@", peerChannel_);
  
  UIScreen *screen = [UIScreen mainScreen];
  CGSize screenSize = screen.bounds.size;
  NSDictionary *screenSizeDict = (__bridge_transfer NSDictionary*)CGSizeCreateDictionaryRepresentation(screenSize);
  UIDevice *device = [UIDevice currentDevice];
  NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                        device.localizedModel, @"localizedModel",
                        [NSNumber numberWithBool:device.multitaskingSupported], @"multitaskingSupported",
                        device.name, @"name",
                        (UIDeviceOrientationIsLandscape(device.orientation) ? @"landscape" : @"portrait"), @"orientation",
                        device.systemName, @"systemName",
                        device.systemVersion, @"systemVersion",
                        screenSizeDict, @"screenSize",
                        [NSNumber numberWithDouble:screen.scale], @"screenScale",
                        nil];
  dispatch_data_t payload = [info createReferencingDispatchData];
  [peerChannel_ sendFrameOfType:PTExampleFrameTypeDeviceInfo tag:PTFrameNoTag withPayload:(NSData *)payload callback:^(NSError *error) {
    if (error) {
      NSLog(@"Failed to send PTExampleFrameTypeDeviceInfo: %@", error);
    }
  }];
}
@end
