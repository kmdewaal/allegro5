#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGLDrawable.h>

#import "EAGLView.h"
#include <pthread.h>

#include "allegro5/allegro_iphone.h"

ALLEGRO_DEBUG_CHANNEL("iphone")

static double allegro_iphone_shake_time = 0.0;
static float allegro_iphone_battery_level = 1.0;

typedef struct touch_t
{
   int      id;
   UITouch* touch;
} touch_t;

/* Every UITouch have associated touch_t structure. This destructor
 * is used in list which held touch information. While ending touch it will
 * be called and memory will be freed.
 */
static void touch_item_dtor(void* value, void* userdata)
{
   (void)userdata;
   al_free(value);
}

/* Search for touch_t associated with UITouch.
 */
static touch_t* find_touch(_AL_LIST* list, UITouch* nativeTouch)
{
   _AL_LIST_ITEM* item;
   
   for (item = _al_list_front(list); item; item = _al_list_next(list, item)) {
   
      touch_t* touch = (touch_t*)_al_list_item_data(item);
      
      if (touch->touch == nativeTouch)
         return touch;
   }
         
   return NULL;
}

@implementation EAGLView

@synthesize context;
@synthesize backingWidth;
@synthesize backingHeight;


// You must implement this method
+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (void)set_allegro_display:(ALLEGRO_DISPLAY *)display {
   allegro_display = display;

   // Get the layer
   CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
   
   NSString *color_format = kEAGLColorFormatRGBA8;
   if (display->extra_settings.settings[ALLEGRO_COLOR_SIZE] == 16)
      color_format = kEAGLColorFormatRGB565;

   eaglLayer.opaque = YES;
   eaglLayer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
      [NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
      color_format, kEAGLDrawablePropertyColorFormat, nil];

   if (display->flags & ALLEGRO_USE_PROGRAMMABLE_PIPELINE) {
      ALLEGRO_INFO("Attempting to create ES2 context\n");
      context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
      if (context == nil) {
         ALLEGRO_WARN("ES2 context could not be created. Attempting to create ES1 context instead.\n");
         display->flags &= ~ ALLEGRO_USE_PROGRAMMABLE_PIPELINE;
         context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
      }
   }
   else {
      ALLEGRO_INFO("Attempting to create ES1 context.\n");
      context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
   }

   ALLEGRO_INFO("Context is %p\n", context);
   
   if (!context || ![EAGLContext setCurrentContext:context]) {
      ALLEGRO_ERROR("context is nil or setCurrentContext failed.\n");
      [self release];
      return;
   }
   
   /* FIXME: Make this depend on a display setting. */
   [self setMultipleTouchEnabled:YES];
   
   ALLEGRO_INFO("Created EAGLView.\n");
}

- (id)initWithFrame:(CGRect)frame {
    
    self = [super initWithFrame:frame];
    
    touch_list = _al_list_create();
    
    primary_touch = NULL;
    
    touch_id_set       = [[NSMutableIndexSet alloc] init];
    next_free_touch_id = 1;

   [UIDevice currentDevice].batteryMonitoringEnabled = YES;
   if ([[UIDevice currentDevice] batteryState] == UIDeviceBatteryStateCharging || [[UIDevice currentDevice] batteryState] == UIDeviceBatteryStateFull || !([[UIDevice currentDevice] isBatteryMonitoringEnabled]))
      allegro_iphone_battery_level = 1.0;
   else
      allegro_iphone_battery_level = [[UIDevice currentDevice] batteryLevel];

   // Register for battery level and state change notifications.
   [[NSNotificationCenter defaultCenter] addObserver:self
      selector:@selector(batteryLevelDidChange:)
      name:UIDeviceBatteryLevelDidChangeNotification object:nil];

   [[NSNotificationCenter defaultCenter] addObserver:self
      selector:@selector(batteryLevelDidChange:)
      name:UIDeviceBatteryStateDidChangeNotification object:nil];

    return self;
}

- (void)batteryLevelDidChange:(NSNotification *)notification
{
    (void)notification;
	if ([[UIDevice currentDevice] batteryState] == UIDeviceBatteryStateCharging || [[UIDevice currentDevice] batteryState] == UIDeviceBatteryStateFull)
		allegro_iphone_battery_level = 1.0;
	else
		allegro_iphone_battery_level = [[UIDevice currentDevice] batteryLevel];
}

- (void)make_current {
    [EAGLContext setCurrentContext:context];
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
}

- (void)reset_framebuffer {
   glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
}

- (void)flip {
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
    [context presentRenderbuffer:GL_RENDERBUFFER_OES];
}

- (void)layoutSubviews {
    [EAGLContext setCurrentContext:context];
    [self destroyFramebuffer];
    [self createFramebuffer];
    ALLEGRO_INFO("Initialized EAGLView.\n");
}


- (BOOL)createFramebuffer {
    if ([self respondsToSelector:@selector(contentScaleFactor)]) {
        self.contentScaleFactor = al_iphone_get_screen_scale();
        ALLEGRO_INFO("Screen scale is %f\n", self.contentScaleFactor);
    }

    ALLEGRO_INFO("Creating GL framebuffer.\n");
    glGenFramebuffersOES(1, &viewFramebuffer);
    glGenRenderbuffersOES(1, &viewRenderbuffer);
    
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
    [context renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:(CAEAGLLayer*)self.layer];
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_RENDERBUFFER_OES, viewRenderbuffer);
    
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &backingWidth);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &backingHeight);
    
    if (allegro_display->extra_settings.settings[ALLEGRO_DEPTH_SIZE]) {
        glGenRenderbuffersOES(1, &depthRenderbuffer);
        glBindRenderbufferOES(GL_RENDERBUFFER_OES, depthRenderbuffer);
        glRenderbufferStorageOES(GL_RENDERBUFFER_OES, GL_DEPTH_COMPONENT16_OES, backingWidth, backingHeight);
        glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES, GL_RENDERBUFFER_OES, depthRenderbuffer);
    }
    
    if (glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES) != GL_FRAMEBUFFER_COMPLETE_OES) {
        NSLog(@"failed to make complete framebuffer object %x", glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES));
        return NO;
    }
    
    return YES;
}


- (void)destroyFramebuffer {
    
    glDeleteFramebuffersOES(1, &viewFramebuffer);
    viewFramebuffer = 0;
    glDeleteRenderbuffersOES(1, &viewRenderbuffer);
    viewRenderbuffer = 0;
    
    if (depthRenderbuffer) {
        glDeleteRenderbuffersOES(1, &depthRenderbuffer);
        depthRenderbuffer = 0;
    }
}

- (void)dealloc {
    if (touch_list)
      _al_list_destroy(touch_list);

    [touch_id_set release]; 

    if ([EAGLContext currentContext] == context) {
        [EAGLContext setCurrentContext:nil];
    }
    
    [context release];  
    [super dealloc];
}

/* Handling of touch events. */

-(NSArray*)getSortedTouches:(NSSet*)touches
{
   NSArray* unsorted = [NSArray arrayWithArray: [touches allObjects]];
   NSArray* sorted   = [unsorted sortedArrayUsingComparator: ^(id obj1, id obj2)
   {
     if ([obj1 timestamp] > [obj2 timestamp])
       return (NSComparisonResult)NSOrderedDescending;
     else if ([obj1 timestamp] < [obj2 timestamp])
       return (NSComparisonResult)NSOrderedAscending;
     else
       return (NSComparisonResult)NSOrderedSame;
   }];
   return sorted;
}

// Handles the start of a touch
-(void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
   (void)event;

   // TODO: handle double-clicks (send two events?)
   // NSUInteger numTaps = [[touches anyObject] tapCount];
   // Enumerate through all the touch objects.
   
   for (UITouch *nativeTouch in touches) {
      /* Create new touch_t and associate ID with UITouch. */
      touch_t* touch = al_malloc(sizeof(touch_t));
      
      touch->touch = nativeTouch;
      
      if ([touch_id_set count] != 0) {
         touch->id = [touch_id_set firstIndex];
         [touch_id_set removeIndex:touch->id];
      }
      else
         touch->id = next_free_touch_id++;
      
      _al_list_push_back_ex(touch_list, touch, touch_item_dtor);
      
      CGPoint p = [nativeTouch locationInView:self];
      p.x *= al_iphone_get_screen_scale();
      p.y *= al_iphone_get_screen_scale();
      
      if (NULL == primary_touch)
         primary_touch = nativeTouch;
      
      _al_iphone_touch_input_handle_begin(touch->id, al_get_time(),
      p.x, p.y, primary_touch == nativeTouch, allegro_display);
   }
}

// Handles the continuation of a touch.
-(void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{  
   (void)event;

   touch_t* touch;
   
   // Enumerates through all touch objects
   for (UITouch *nativeTouch in touches) {
      if ((touch = find_touch(touch_list, nativeTouch))) {
   
         CGPoint p = [nativeTouch locationInView:self];
         p.x *= al_iphone_get_screen_scale();
         p.y *= al_iphone_get_screen_scale();
   
         _al_iphone_touch_input_handle_move(touch->id, al_get_time(),
         p.x, p.y, primary_touch == nativeTouch, allegro_display);         
   
      }
   }
}

// Handles the end of a touch event.
-(void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
   (void)event;
   
   touch_t* touch;
   
   // Enumerates through all touch objects
   for (UITouch *nativeTouch in touches) {
      if ((touch = find_touch(touch_list, nativeTouch))) {

         CGPoint p = [nativeTouch locationInView:self];
         p.x *= al_iphone_get_screen_scale();
         p.y *= al_iphone_get_screen_scale();


         _al_iphone_touch_input_handle_end(touch->id, al_get_time(),
            p.x, p.y, primary_touch == nativeTouch, allegro_display);  

         [touch_id_set addIndex:touch->id];
         _al_list_remove(touch_list, touch);

         if (primary_touch == nativeTouch)
            primary_touch = NULL;
      }
   }
}

// Qooting Apple docs:
// "The system cancelled tracking for the touch, as when (for example) the user
// puts the device to his or her face."
-(void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
   (void)event;
    
   touch_t* touch;
   
   // Enumerates through all touch objects
   for (UITouch *nativeTouch in touches) {
      if ((touch = find_touch(touch_list, nativeTouch))) {
   
         CGPoint p = [nativeTouch locationInView:self];
         p.x *= al_iphone_get_screen_scale();
         p.y *= al_iphone_get_screen_scale();
         
         _al_iphone_touch_input_handle_cancel(touch->id, al_get_time(),
         p.x, p.y, primary_touch == nativeTouch, allegro_display);
         
         if (primary_touch == nativeTouch)
         primary_touch = NULL;            
         
         [touch_id_set addIndex:touch->id];
         _al_list_remove(touch_list, touch);
      }
   }
}

-(BOOL)canBecomeFirstResponder {
    return YES;
}

-(void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    (void)motion;

	if (event.subtype == UIEventSubtypeMotionShake) {
		allegro_iphone_shake_time = al_get_time();
	}
}

@end

/* Function: al_iphone_get_last_shake_time
 */
double al_iphone_get_last_shake_time(void)
{
	return allegro_iphone_shake_time;
}

/* Function: al_iphone_get_battery_level
 */
float al_iphone_get_battery_level(void)
{
	return allegro_iphone_battery_level;
}
