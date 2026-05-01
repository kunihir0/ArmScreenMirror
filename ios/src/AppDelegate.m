#import "AppDelegate.h"
#import "ViewController.h"
#import <stdio.h>

static FILE *g_logFile = NULL;

static void smir_log_redirect(void) {
    // Tee NSLog/printf a /tmp/screenmirror.log para depuración remota.
    NSString *path = @"/tmp/screenmirror.log";
    g_logFile = fopen(path.UTF8String, "a");
    if (!g_logFile) return;
    setvbuf(g_logFile, NULL, _IOLBF, 0);
    dup2(fileno(g_logFile), STDOUT_FILENO);
    dup2(fileno(g_logFile), STDERR_FILENO);
    NSLog(@"---- ScreenMirror launched %@ ----", [NSDate date]);
}

@implementation AppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    smir_log_redirect();

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];

    [app setIdleTimerDisabled:YES];
    return YES;
}

@end
