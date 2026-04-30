// auto_mount.m
// 自动挂载 NAS 工具
// 当连接到指定 WiFi 时，静默挂载指定的网络卷宗
//
// 首次运行：sudo ./auto_mount --init
// 后续运行：./auto_mount

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <NetFS/NetFS.h>

// 从 argv[0] 获取程序所在目录
static NSString* getAppDir() {
    NSString *exePath = [[NSProcessInfo processInfo].arguments[0] stringByStandardizingPath];
    return [exePath stringByDeletingLastPathComponent];
}

// 日志文件路径（程序同目录下）
#define LOG_FILE ([getAppDir() stringByAppendingPathComponent:@"auto_mount.log"])

// 写入日志（带时间戳）
void writeLog(NSString *message) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *logLine = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    NSString *logDir = [LOG_FILE stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:LOG_FILE];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logLine dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logLine writeToFile:LOG_FILE atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// 配置文件路径（程序同目录下）
static NSString* getConfigPath() {
    NSString *exePath = [[NSProcessInfo processInfo].arguments[0] stringByStandardizingPath];
    return [[exePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"auto_mount.plist"];
}

// 前向声明
NSDictionary* loadConfig();
NSString* extractHostname(NSString *smbURL);

// 配置：要挂载的卷宗
static NSArray *getMountTargets() {
    NSDictionary *config = loadConfig();
    NSArray *targets = config[@"mount_targets"];
    if (targets == nil || targets.count == 0) {
        fprintf(stderr, "✗ No mount_targets found. Please run: sudo ./auto_mount --init\n");
        exit(1);
    }
    return targets;
}

// 保存配置
void saveConfig(NSString *fingerprint, NSArray *mountTargets) {
    NSDictionary *config = @{
        @"target_gateway_mac": fingerprint ?: @"",
        @"mount_targets": mountTargets ?: @[],
        @"created_at": [NSDate date],
    };
    NSString *configDir = [getConfigPath() stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:configDir 
                              withIntermediateDirectories:YES 
                                               attributes:nil 
                                                    error:nil];
    [config writeToFile:getConfigPath() atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644} 
                                 ofItemAtPath:getConfigPath() 
                                        error:nil];
    printf("✓ Config saved to: %s\n", [getConfigPath() UTF8String]);
    printf("  Target Gateway MAC: %s\n", [fingerprint UTF8String]);
    printf("  Mount targets: %d\n", (int)[mountTargets count]);
}

// 加载配置
NSDictionary* loadConfig() {
    return [NSDictionary dictionaryWithContentsOfFile:getConfigPath()];
}

// 交互式输入挂载卷宗
NSArray* inputMountTargets() {
    printf("\n[2] Configuring mount targets...\n");
    NSMutableArray *targets = [NSMutableArray array];
    char input[256];
    while (YES) {
        printf("  Enter SMB URL (or press Enter to finish): ");
        if (fgets(input, sizeof(input), stdin) == NULL) break;
        input[strcspn(input, "\n")] = 0;
        NSString *url = [NSString stringWithUTF8String:input];
        if (url.length == 0) break;
        printf("  Enter mount path: ");
        if (fgets(input, sizeof(input), stdin) == NULL) break;
        input[strcspn(input, "\n")] = 0;
        NSString *path = [NSString stringWithUTF8String:input];
        if (path.length == 0) {
            fprintf(stderr, "  ✗ Path cannot be empty.\n");
            continue;
        }
        [targets addObject:@{@"url": url, @"path": path}];
        printf("  ✓ Added: %s -> %s\n", [url UTF8String], [path UTF8String]);
        printf("  Add another? (y/n): ");
        if (fgets(input, sizeof(input), stdin) == NULL) break;
        input[strcspn(input, "\n")] = 0;
        if (strcasecmp(input, "y") != 0 && strcasecmp(input, "yes") != 0) break;
    }
    if (targets.count == 0) printf("  No mount targets configured.\n");
    return targets;
}

// 获取物理网关IP (穿透 TUN 隧道)
NSString* getPhysicalGatewayIP() {
    NSArray *interfaces = @[@"en0", @"en1", @"en2", @"en3"];
    for (NSString *interface in interfaces) {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/usr/sbin/ipconfig"];
        [task setArguments:@[@"getoption", interface, @"router"]];
        NSPipe *pipe = [NSPipe pipe];
        [task setStandardOutput:pipe];
        [task launch];
        [task waitUntilExit];
        if ([task terminationStatus] == 0) {
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            output = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (output.length > 0) {
                return output;
            }
        }
    }
    return nil;
}

// 根据IP获取MAC地址 (二层 ARP 协议)
NSString* getMACAddressForIP(NSString *ip) {
    if (!ip || ip.length == 0) return nil;
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/sbin/arp"];
    [task setArguments:@[@"-n", ip]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    [task waitUntilExit];
    if ([task terminationStatus] == 0) {
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        // Parse output: ? (192.168.1.1) at b0:be:76:xx:xx:xx on en0 ifscope [ethernet]
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"at\\s+([0-9a-fA-F:]+)\\s+on" options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];
        if (match) {
            NSString *mac = [output substringWithRange:[match rangeAtIndex:1]];
            return [mac lowercaseString];
        }
    }
    return nil;
}

// 获取当前网络指纹（物理路由器的 MAC 地址）
NSString* getCurrentNetworkFingerprint() {
    NSString *gatewayIP = getPhysicalGatewayIP();
    if (gatewayIP) {
        return getMACAddressForIP(gatewayIP);
    }
    return nil;
}

// 检查挂载点是否已挂载
BOOL isMounted(NSString *mountPath) {
    FILE *fp = popen("/sbin/mount", "r");
    if (fp == NULL) return NO;
    char line[1024];
    BOOL found = NO;
    while (fgets(line, sizeof(line), fp) != NULL) {
        if (strstr(line, [mountPath UTF8String]) != NULL) { found = YES; break; }
    }
    pclose(fp);
    return found;
}

// 静默挂载网络卷宗
BOOL silentMount(NSString *smbURL) {
    NSURL *url = [NSURL URLWithString:smbURL];
    if (url == nil) {
        fprintf(stderr, "  ✗ Invalid URL: %s\n", [smbURL UTF8String]);
        return NO;
    }
    CFURLRef cfURL = (__bridge CFURLRef)url;
    CFArrayRef mountPoints = NULL;
    OSStatus status = NetFSMountURLSync(cfURL, NULL, NULL, NULL, NULL, NULL, &mountPoints);
    if (mountPoints != NULL) CFRelease(mountPoints);
    if (status == noErr) {
        printf("  ✓ Mounted: %s\n", [smbURL UTF8String]);
        return YES;
    } else {
        fprintf(stderr, "  ✗ Failed to mount: %s (error: %d)\n", [smbURL UTF8String], (int)status);
        writeLog([NSString stringWithFormat:@"Failed to mount: %@ (error: %d)", smbURL, (int)status]);
        return NO;
    }
}

// 从 SMB URL 中提取 hostname
NSString* extractHostname(NSString *smbURL) {
    NSString *hostPart = smbURL;
    if ([hostPart hasPrefix:@"smb://"]) hostPart = [hostPart substringFromIndex:6];
    NSRange slashRange = [hostPart rangeOfString:@"/"];
    if (slashRange.location != NSNotFound) hostPart = [hostPart substringToIndex:slashRange.location];
    return hostPart;
}

// 打印使用说明
void printUsage() {
    printf("Auto Mount Tool\n===============\n\nUsage:\n  ./auto_mount --init         First time setup (No sudo required)\n  ./auto_mount                Normal run\n  ./auto_mount --help         Help\n\nConfig file: %s\n", [getConfigPath() UTF8String]);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        BOOL isInit = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--init") == 0) isInit = YES;
            else if (strcmp(argv[i], "--help") == 0) { printUsage(); return 0; }
        }
        
        if (isInit) {
            printf("Auto Mount Tool - Init Mode\n===========================\n\n");
            printf("[1] Getting current network fingerprint (Gateway MAC)...\n");
            NSString *fingerprint = getCurrentNetworkFingerprint();
            if (fingerprint == nil) {
                fprintf(stderr, "✗ Could not get network fingerprint. Are you connected to a network?\n");
                writeLog(@"Could not get network fingerprint");
                return 1;
            }
            printf("  Current Gateway MAC: %s\n", [fingerprint UTF8String]);
            NSArray *mountTargets = inputMountTargets();
            saveConfig(fingerprint, mountTargets);
            printf("\n[DONE] Init complete! You can now run './auto_mount' seamlessly.\n");
            return 0;
        }
        
        printf("Auto Mount Tool\n===============\n\n");
        printf("[1] Loading config...\n");
        NSDictionary *config = loadConfig();
        if (config == nil) {
            fprintf(stderr, "✗ Config not found. Run: ./auto_mount --init\n");
            writeLog(@"Config not found, exiting");
            return 1;
        }
        // 兼容老版本的 target_ssid 字段
        NSString *targetFingerprint = config[@"target_gateway_mac"] ?: config[@"target_ssid"];
        if (!targetFingerprint) {
            fprintf(stderr, "✗ Invalid config. Run: ./auto_mount --init\n");
            writeLog(@"Invalid config, exiting");
            return 1;
        }
        printf("  Target Gateway MAC: %s\n", [targetFingerprint UTF8String]);
        
        // 检查当前网络环境（指纹比对）
        printf("\n[2] Checking network fingerprint...\n");
        NSString *currentFingerprint = getCurrentNetworkFingerprint();
        if (currentFingerprint == nil) {
            printf("  ✗ No physical network connection found, exiting.\n");
            writeLog(@"No physical network connection found, exiting");
            return 0;
        }
        printf("  Current Gateway MAC: %s\n", [currentFingerprint UTF8String]);
        
        if (![currentFingerprint isEqualToString:targetFingerprint] && ![currentFingerprint isEqualToString:[targetFingerprint lowercaseString]]) {
            printf("  ✗ Network fingerprint mismatch, skipping mount.\n");
            writeLog(@"Network fingerprint mismatch, skipping mount");
            return 0;
        }
        printf("  ✓ Network fingerprint matched!\n");
        
        // 检查网络（ping NAS）- 必须通才算在目标网络
        printf("\n[3] Checking network...\n");
        NSArray *allTargets = getMountTargets();
        NSString *nasHostname = extractHostname(allTargets[0][@"url"]);
        printf("  NAS hostname: %s\n", [nasHostname UTF8String]);
        
        BOOL serverReachable = NO;
        for (int retry = 0; retry < 3 && !serverReachable; retry++) {
            if (retry > 0) {
                printf("  Retrying... (%d/3)\n", retry + 1);
                [NSThread sleepForTimeInterval:2.0];
            }
            NSTask *pingTask = [[NSTask alloc] init];
            [pingTask setLaunchPath:@"/sbin/ping"];
            [pingTask setArguments:@[@"-c", @"2", nasHostname]];
            NSPipe *pingPipe = [NSPipe pipe];
            [pingTask setStandardOutput:pingPipe];
            [pingTask setStandardError:pingPipe];
            [pingTask launch];
            [pingTask waitUntilExit];
            if ([pingTask terminationStatus] == 0) serverReachable = YES;
        }
        
        if (!serverReachable) {
            printf("  ✗ Server not reachable, exiting.\n");
            writeLog(@"Server not reachable, exiting");
            return 0;
        }
        printf("  ✓ Server reachable!\n");
        
        // 遍历挂载
        printf("\n[4] Checking mount points...\n");
        NSArray *targets = getMountTargets();
        int mounted_count = 0;
        for (NSDictionary *target in targets) {
            NSString *mountPath = target[@"path"];
            NSString *smbURL = target[@"url"];
            printf("  %s: ", [mountPath UTF8String]);
            if (isMounted(mountPath)) {
                printf("already mounted, skipping.\n");
                mounted_count++;
                continue;
            }
            printf("not mounted, mounting...\n");
            if (silentMount(smbURL)) mounted_count++;
        }
        printf("\n[DONE] %d/%d volumes mounted.\n", mounted_count, (int)[targets count]);
    }
    return 0;
}