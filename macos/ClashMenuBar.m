#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property NSStatusItem *statusItem;
@property NSDictionary *config;
@property NSString *currentNode;
@property NSNumber *currentDelay;
@property NSDate *lastChecked;
@property BOOL busy;
@property NSMenuItem *nodeItem;
@property NSMenuItem *delayItem;
@property NSMenuItem *checkedItem;
@property NSMenuItem *switchItem;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.currentNode = @"读取中…";
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"-- ms";
    self.statusItem.button.toolTip = @"Clash 当前节点延迟";

    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    self.nodeItem = [[NSMenuItem alloc] initWithTitle:@"当前节点：读取中…" action:nil keyEquivalent:@""];
    self.delayItem = [[NSMenuItem alloc] initWithTitle:@"实时延迟：--" action:nil keyEquivalent:@""];
    self.checkedItem = [[NSMenuItem alloc] initWithTitle:@"上次检测：--" action:nil keyEquivalent:@""];
    for (NSMenuItem *item in @[self.nodeItem, self.delayItem, self.checkedItem]) {
        item.enabled = NO; [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"立即重新检测" action:@selector(refreshCurrent) keyEquivalent:@""];
    refresh.target = self; [menu addItem:refresh];
    self.switchItem = [[NSMenuItem alloc] initWithTitle:@"检测全部并切换最快节点" action:@selector(switchFastest) keyEquivalent:@""];
    self.switchItem.target = self; [menu addItem:self.switchItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"打开 Clash Verge" action:@selector(openClash) keyEquivalent:@""];
    open.target = self; [menu addItem:open];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出" action:@selector(quit) keyEquivalent:@""];
    quit.target = self; [menu addItem:quit];
    self.statusItem.menu = menu;

    NSString *path = [[NSBundle mainBundle] pathForResource:@"config" ofType:@"json"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSError *error;
    self.config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (!self.config) {
        self.statusItem.button.title = @"配置错误";
        self.statusItem.button.toolTip = error.localizedDescription ?: @"App 中缺少 config.json";
        return;
    }

    NSURL *controllerURL = [NSURL URLWithString:self.config[@"controller"]];
    NSString *host = controllerURL.host.lowercaseString;
    BOOL isLocal = [host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"] || [host isEqualToString:@"::1"];
    BOOL allowInsecure = [self.config[@"allowInsecureRemote"] boolValue];
    if (!controllerURL || (!isLocal && [controllerURL.scheme.lowercaseString isEqualToString:@"http"] && !allowInsecure)) {
        self.statusItem.button.title = @"配置错误";
        self.statusItem.button.toolTip = @"远程 Controller 必须使用 HTTPS";
        return;
    }

    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
        completionHandler:^(__unused BOOL granted, __unused NSError *error) {}];
    [self refreshCurrent];
    [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(refreshCurrent) userInfo:nil repeats:YES];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self switchFastest];
    return YES;
}

- (NSString *)encoded:(NSString *)value {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
}

- (void)requestPath:(NSString *)path method:(NSString *)method body:(NSData *)body completion:(void (^)(id, NSError *))completion {
    NSString *base = [self.config[@"controller"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]];
    request.HTTPMethod = method;
    request.HTTPBody = body;
    request.timeoutInterval = [self.config[@"timeout"] doubleValue] / 1000.0 + 2;
    NSString *secret = self.config[@"secret"];
    if (secret.length) [request setValue:[@"Bearer " stringByAppendingString:secret] forHTTPHeaderField:@"Authorization"];
    if (body) [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (!error && (status < 200 || status >= 300)) {
            error = [NSError errorWithDomain:@"ClashMenuBar" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Clash API 返回 %ld", (long)status]}];
        }
        id json = (!error && data.length) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        completion(json, error);
    }] resume];
}

- (NSString *)delayPathForNode:(NSString *)node {
    NSURLComponents *components = [NSURLComponents new];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url" value:self.config[@"testUrl"]],
        [NSURLQueryItem queryItemWithName:@"timeout" value:[self.config[@"timeout"] stringValue]]
    ];
    return [NSString stringWithFormat:@"/proxies/%@/delay?%@", [self encoded:node], components.percentEncodedQuery];
}

- (void)refreshCurrent {
    if (self.busy) return;
    [self requestPath:@"/proxies" method:@"GET" body:nil completion:^(id json, NSError *error) {
        NSString *node = json[@"proxies"][self.config[@"group"]][@"now"];
        if (error || !node.length) { [self applyFailure:nil]; return; }
        self.currentNode = node;
        [self requestPath:[self delayPathForNode:node] method:@"GET" body:nil completion:^(id delayJSON, NSError *delayError) {
            NSNumber *delay = delayJSON[@"delay"];
            if (delayError || delay.integerValue <= 0) [self applyFailure:node];
            else [self applyDelay:delay node:node];
        }];
    }];
}

- (BOOL)name:(NSString *)name matches:(NSString *)pattern {
    if (!pattern.length) return YES;
    return [name rangeOfString:pattern options:(NSRegularExpressionSearch | NSCaseInsensitiveSearch)].location != NSNotFound;
}

- (void)switchFastest {
    if (self.busy) return;
    [self updateBusyState:YES];
    [self requestPath:@"/proxies" method:@"GET" body:nil completion:^(id json, NSError *error) {
        NSArray *all = json[@"proxies"][self.config[@"group"]][@"all"];
        if (error || !all.count) { [self finishSwitch:@"无法读取节点列表" success:NO]; return; }
        NSString *include = self.config[@"filter"] ?: @"";
        NSString *exclude = self.config[@"exclude"] ?: @"";
        NSMutableArray *nodes = [NSMutableArray new];
        for (NSString *name in all) {
            if ([self name:name matches:include] && (!exclude.length || ![self name:name matches:exclude])) [nodes addObject:name];
        }
        if (!nodes.count) { [self finishSwitch:@"没有匹配过滤条件的节点" success:NO]; return; }

        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t lockQueue = dispatch_queue_create("com.local.clash-fastest-node.results", DISPATCH_QUEUE_SERIAL);
        NSMutableArray<NSDictionary *> *results = [NSMutableArray new];
        for (NSString *node in nodes) {
            dispatch_group_enter(group);
            [self requestPath:[self delayPathForNode:node] method:@"GET" body:nil completion:^(id delayJSON, NSError *delayError) {
                NSNumber *delay = delayJSON[@"delay"];
                NSInteger maxDelay = [self.config[@"maxDelay"] integerValue];
                if (!delayError && delay.integerValue > 0 && (maxDelay == 0 || delay.integerValue <= maxDelay)) {
                    dispatch_sync(lockQueue, ^{ [results addObject:@{ @"name": node, @"delay": delay }]; });
                }
                dispatch_group_leave(group);
            }];
        }
        dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *best = [results sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"delay"] compare:b[@"delay"]];
            }].firstObject;
            if (!best) { [self finishSwitch:@"没有可用节点" success:NO]; return; }
            NSData *body = [NSJSONSerialization dataWithJSONObject:@{ @"name": best[@"name"] } options:0 error:nil];
            NSString *path = [NSString stringWithFormat:@"/proxies/%@", [self encoded:self.config[@"group"]]];
            [self requestPath:path method:@"PUT" body:body completion:^(__unused id response, NSError *selectError) {
                if (selectError) [self finishSwitch:selectError.localizedDescription success:NO];
                else {
                    [self applyDelay:best[@"delay"] node:best[@"name"]];
                    [self finishSwitch:[NSString stringWithFormat:@"%@（%@ ms）", best[@"name"], best[@"delay"]] success:YES];
                }
            }];
        });
    }];
}

- (void)applyDelay:(NSNumber *)delay node:(NSString *)node {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentNode = node; self.currentDelay = delay; self.lastChecked = [NSDate date];
        self.statusItem.button.title = [NSString stringWithFormat:@"%@ ms", delay];
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"%@ · %@ ms", node, delay];
        [self updateMenu];
    });
}

- (void)applyFailure:(NSString *)node {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (node) self.currentNode = node;
        self.currentDelay = nil; self.lastChecked = [NSDate date]; self.statusItem.button.title = @"-- ms";
        [self updateMenu];
    });
}

- (void)updateBusyState:(BOOL)busy {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.busy = busy; self.switchItem.enabled = !busy;
        self.statusItem.button.title = busy ? @"测速中…" : (self.currentDelay ? [NSString stringWithFormat:@"%@ ms", self.currentDelay] : @"-- ms");
    });
}

- (void)finishSwitch:(NSString *)message success:(BOOL)success {
    [self updateBusyState:NO];
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = success ? @"Clash 节点已刷新" : @"Clash 节点切换失败";
    content.body = message;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

- (void)menuWillOpen:(NSMenu *)menu { [self updateMenu]; }
- (void)updateMenu {
    self.nodeItem.title = [@"当前节点：" stringByAppendingString:self.currentNode ?: @"--"];
    self.delayItem.title = self.currentDelay ? [NSString stringWithFormat:@"实时延迟：%@ ms", self.currentDelay] : @"实时延迟：检测失败";
    if (self.lastChecked) self.checkedItem.title = [@"上次检测：" stringByAppendingString:[NSDateFormatter localizedStringFromDate:self.lastChecked dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];
}

- (void)openClash {
    for (NSString *path in @[@"/Applications/Clash Verge.app", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/Clash Verge.app"]]) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:path] configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
            return;
        }
    }
}
- (void)quit { [NSApp terminate:nil]; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
