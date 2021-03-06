//
//  FUManager.m
//  P2A
//
//  Created by L on 2018/12/17.
//  Copyright © 2018年 L. All rights reserved.
//

#import "FUManager.h"
#import "authpack.h"
#import "FURequestManager.h"
#import "FUAvatar.h"
#import "FUP2AColor.h"


@interface FUManager ()
@end

@implementation FUManager
#pragma mark ----- LifeCycle
static FUManager *fuManager = nil;
+ (instancetype)shareInstance
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fuManager = [[FUManager alloc] init];
    });
    return fuManager;
}

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        [self initFaceUnity];
        [self initLibrary];
        // 生成空buffer
        [self initPixelBuffer];
        
        [self initProperty];
        [self initDefaultItem];
        
        self.rotatedImageManager = [[FURotatedImage alloc]init];
        
        [self initFaceCapture];
        [self bindFaceCaptureToController];
        [self useFaceCapure:YES];
        
        // 关闭nama的打印
        [FURenderer itemSetParam:self.defalutQController withName:@"FUAI_VLogSetLevel" value:@(0)];
    }
    return self;
}

#pragma mark ----- 初始化 ------
- (void)initProperty
{
    self.currentAvatars = [NSMutableArray arrayWithCapacity:1];
    frameSize = CGSizeZero;
    signal = dispatch_semaphore_create(1);
    isCreatingAvatar = NO;
}

- (void)initLibrary
{
    // 设置鉴权
    [[FUP2AHelper shareInstance] setupHelperWithAuthPackage:&g_auth_package authSize:sizeof(g_auth_package)];

    [FUP2AHelper shareInstance].saveVideoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fup2a_video.mp4"];
    [[FUP2AHelper shareInstance] startRecordWithType:FUP2AHelperRecordTypeVoicedVideo];
}

//初始化FaceUnity
- (void)initFaceUnity
{
    NSString *path = [[NSBundle mainBundle] pathForResource:@"v3.bundle" ofType:nil];
    int ret =  [[FURenderer shareRenderer] setupWithDataPath:path authPackage:&g_auth_package authSize:sizeof(g_auth_package) shouldCreateContext:YES];
    NSLog(@"%d",ret);
    [FURenderer setMaxFaces:1];
}

//加载默认数据
- (void)initDefaultItem
{
    // 加载抗锯齿
    NSString *filePath = [[NSBundle mainBundle] pathForResource:@"fxaa" ofType:@"bundle"];
    mItems[0] = [FURenderer itemWithContentsOfFile:filePath];
    
    // 加载舌头
    NSData *tongueData = [NSData dataWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"tongue.bundle" ofType:nil]];
    [FURenderer loadTongueModel:(void *)tongueData.bytes size:(int)tongueData.length];
    
    //加载controller
    NSString *controller =   @"q_controller.bundle";
    NSString *controllerPath = [[NSBundle mainBundle] pathForResource:controller ofType:nil];
    self.defalutQController = [FURenderer itemWithContentsOfFile:controllerPath];
    
    //加载controller_config
    NSString *controller_config_path = [[NSBundle mainBundle] pathForResource:@"controller_config" ofType:@"bundle"];
    [self rebindItemToControllerWithFilepath:controller_config_path withPtr:&q_controller_config_ptr];
    
    [self loadDefaultBackGroundToController];
}

//初始化P2AClient库
- (void)loadClientDataWithFirstSetup:(BOOL)firstSetup
{
    NSString *qPath;
    switch (self.avatarStyle)
    {
        case FUAvatarStyleNormal:
        {
            if (![[NSFileManager defaultManager] fileExistsAtPath:AvatarListPath])
            {
                [[NSFileManager defaultManager] createDirectoryAtPath:AvatarListPath withIntermediateDirectories:YES attributes:nil error:nil];
            }
            qPath =[[NSBundle mainBundle] pathForResource:@"p2a_client_q" ofType:@"bin"];
        }
            break;
        case FUAvatarStyleQ:
        {
            if (![[NSFileManager defaultManager] fileExistsAtPath:AvatarQPath])
            {
                [[NSFileManager defaultManager] createDirectoryAtPath:AvatarQPath withIntermediateDirectories:YES attributes:nil error:nil];
            }
            qPath =[[NSBundle mainBundle] pathForResource:@"p2a_client_q1" ofType:@"bin"];
        }
            break;
    }
    // p2a bin
    if (firstSetup)
    {
        NSString *corePath = [[NSBundle mainBundle] pathForResource:@"p2a_client_core" ofType:@"bin"];
        [[fuPTAClient shareInstance] setupCore:corePath authPackage:&g_auth_package authSize:sizeof(g_auth_package)];
    }
    [[fuPTAClient shareInstance] setupCustomData:qPath];
}

#pragma mark ------ 图像 ------
/// 初始化空白buffer
- (void)initPixelBuffer
{
    if (!renderTarget)
    {
        CGSize size = [UIScreen mainScreen].currentMode.size;
        renderTarget=[self createEmptyPixelBuffer:size];
    }
    if (!screenShotTarget)
    {
        screenShotTarget=[self createEmptyPixelBuffer:CGSizeMake(460, 630)];
    }
}

/// 创建空白buffer
/// @param size buffer的大小
- (CVPixelBufferRef)createEmptyPixelBuffer:(CGSize)size
{
    CVPixelBufferRef ret;
    NSDictionary* pixelBufferOptions = @{ (NSString*) kCVPixelBufferPixelFormatTypeKey :
                                              @(kCVPixelFormatType_32BGRA),
                                          (NSString*) kCVPixelBufferWidthKey : @(size.width),
                                          (NSString*) kCVPixelBufferHeightKey : @(size.height),
                                          (NSString*) kCVPixelBufferOpenGLESCompatibilityKey : @YES,
                                          (NSString*) kCVPixelBufferIOSurfacePropertiesKey : @{}};
    CVPixelBufferCreate(kCFAllocatorDefault,
                        size.width, size.height,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)pixelBufferOptions,
                        &ret);
    return ret;
}

/**
 检测人脸接口
 
 @param sampleBuffer  图像数据
 @return              图像数据
 */
- (CVPixelBufferRef)trackFaceWithBuffer:(CMSampleBufferRef)sampleBuffer CurrentlLightingValue:(float *)currntLightingValue
{
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) ;
    [self trackFace:pixelBuffer];
    
    if (CGSizeEqualToSize(frameSize, CGSizeZero))
    {
        CVPixelBufferLockBaseAddress(pixelBuffer, 0) ;
        int height = (int)CVPixelBufferGetHeight(pixelBuffer) ;
        int width  = (int)CVPixelBufferGetWidth(pixelBuffer) ;
        frameSize = CGSizeMake(width, height) ;
        CVPixelBufferUnlockBaseAddress(pixelBuffer,0);
    }
    
    CFDictionaryRef metadataDict = CMCopyDictionaryOfAttachments(NULL,sampleBuffer, kCMAttachmentMode_ShouldPropagate);
    NSDictionary *metadata = [[NSMutableDictionary alloc] initWithDictionary:(__bridge NSDictionary*)metadataDict];
    CFRelease(metadataDict);
    NSDictionary *exifMetadata = [[metadata objectForKey:(NSString *)kCGImagePropertyExifDictionary] mutableCopy];
    lightingValue = [[exifMetadata objectForKey:(NSString *)kCGImagePropertyExifBrightnessValue] floatValue];
    if(currntLightingValue)
    {
        *currntLightingValue = lightingValue;
    }
    dispatch_semaphore_signal(signal);
    return pixelBuffer ;
}

static int frameId = 0 ;
/**
 Avatar 处理接口
 
 @param pixelBuffer 图像数据
 @param renderMode  render 模式
 @param landmarks   landmarks 数组
 @return            处理之后的图像
 */
- (CVPixelBufferRef)renderP2AItemWithPixelBuffer:(CVPixelBufferRef)pixelBuffer RenderMode:(FURenderMode)renderMode Landmarks:(float *)landmarks LandmarksLength:(int)landmarksLength
{
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    
    FUAvatarInfo* info;
    if(self.useFaceCapure)
    {
        info = [[FUAvatarInfo alloc] init];
        [self enableFaceCapture:(FURenderPreviewMode==renderMode?YES:NO)];
        if(FURenderPreviewMode == renderMode)
        {
            [self trackFace:pixelBuffer];
            if(landmarks)
            {
                [self GetLandmarks:landmarks length:landmarksLength faceIdx:0];
            }
        }
    }
    else
    {
        info = [self GetAvatarInfo:pixelBuffer renderMode:renderMode];
        if(FURenderPreviewMode == renderMode)
        {
            if(landmarks)
            {
                memcpy(landmarks, info->landmarks, sizeof(info->landmarks));
            }
        }
    }
    
    int h = (int)CVPixelBufferGetHeight(renderTarget);
    int stride = (int)CVPixelBufferGetBytesPerRow(renderTarget);
    int w = stride/4;
    CVPixelBufferLockBaseAddress(renderTarget, 0);
    void* pod = (void *)CVPixelBufferGetBaseAddress(renderTarget);
    [[FURenderer shareRenderer] renderBundles:&info->info inFormat:FU_FORMAT_AVATAR_INFO outPtr:pod outFormat:FU_FORMAT_BGRA_BUFFER width:w height:h frameId:frameId++ items:mItems itemCount:sizeof(mItems)/sizeof(int)];
    
    [self rotateImage:pod inFormat:FU_FORMAT_BGRA_BUFFER w:w h:h rotationMode:FU_ROTATION_MODE_0 flipX:NO flipY:YES];
    
    memcpy(pod, self.rotatedImageManager.mData, w*h*4);
    CVPixelBufferUnlockBaseAddress(renderTarget, 0);
    
    dispatch_semaphore_signal(signal);
    
    return renderTarget ;
}

/**
 Avatar 处理接口
 
 @param pixelBuffer 图像数据
 @param rate  缩放比例
 
 @return            处理之后的图像
 */
- (CVPixelBufferRef)renderP2AItemWithPixelBuffer:(CVPixelBufferRef)pixelBuffer HightResolution:(float)rate
{
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    int h = (int)CVPixelBufferGetHeight(pixelBuffer) * rate;
    int w = (int)CVPixelBufferGetWidth(pixelBuffer) * rate;
    CVPixelBufferRef rendered_pixel = [self createEmptyPixelBuffer:CGSizeMake(w, h)];
    CVPixelBufferLockBaseAddress(rendered_pixel, 0);
    void* rendered_pixel_pod = (void *)CVPixelBufferGetBaseAddress(rendered_pixel);
    FUAvatarInfo* info;
    info = [self GetAvatarInfo:pixelBuffer renderMode:FURenderCommonMode];
    [[FURenderer shareRenderer] renderBundles:&info->info inFormat:FU_FORMAT_AVATAR_INFO outPtr:rendered_pixel_pod outFormat:FU_FORMAT_BGRA_BUFFER width:w height:h frameId:frameId++ items:mItems itemCount:sizeof(mItems)/sizeof(int)];
    [self rotateImage:rendered_pixel_pod inFormat:FU_FORMAT_BGRA_BUFFER w:w h:h rotationMode:FU_ROTATION_MODE_0 flipX:NO flipY:YES];
    memcpy(rendered_pixel_pod, self.rotatedImageManager.mData, w*h*4);
    CVPixelBufferUnlockBaseAddress(rendered_pixel, 0);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    dispatch_semaphore_signal(signal);
    return rendered_pixel ;
}

static int ARFilterID = 0 ;
/**
 AR 滤镜处理接口 同时返回捕捉到的脸部点位
 
 @param pixelBuffer 图像数据
 @return            处理之后的图像数据
 */
- (CVPixelBufferRef)renderARFilterItemWithBuffer:(CVPixelBufferRef)pixelBuffer Landmarks:(float *)landmarks LandmarksLength:(int)landmarksLength
{
    
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    
    if(self.useFaceCapure)
    {
        [self trackFace:pixelBuffer];
        if(landmarks)
        {
            [self GetLandmarks:landmarks length:landmarksLength faceIdx:0];
        }
        [self enableFaceCapture:YES];
    }
    
    int h = (int)CVPixelBufferGetHeight(pixelBuffer);
    int stride = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
    int w = stride/4;
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void* pod0 = (void *)CVPixelBufferGetBaseAddress(pixelBuffer);
    [[FURenderer shareRenderer] renderBundles:pod0 inFormat:FU_FORMAT_BGRA_BUFFER outPtr:pod0 outFormat:FU_FORMAT_BGRA_BUFFER width:w height:h frameId:ARFilterID++ items:arItems itemCount:2];
    
    [self rotateImage:pod0 inFormat:FU_FORMAT_BGRA_BUFFER w:w h:h rotationMode:FU_ROTATION_MODE_0 flipX:NO flipY:YES];
    memcpy(pod0, self.rotatedImageManager.mData, w*h*4);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    dispatch_semaphore_signal(signal);
    
    return pixelBuffer;
}


-(CVPixelBufferRef)dealTheFrontCameraPixelBuffer:(CVPixelBufferRef) pixelBuffer
{
    return [self dealTheFrontCameraPixelBuffer:pixelBuffer returnNewBuffer:YES];
}

-(CVPixelBufferRef)dealTheFrontCameraPixelBuffer:(CVPixelBufferRef) pixelBuffer returnNewBuffer:(BOOL)returnNewBuffer
{
    return [self rotateImage:pixelBuffer rotationMode:FU_ROTATION_MODE_0 flipX:YES flipY:NO returnNewBuffer:returnNewBuffer];
}

-(void)rotateImage:(void*)inPtr inFormat:(int)inFormat w:(int)w h:(int)h rotationMode:(int)rotationMode flipX:(BOOL)flipX flipY:(BOOL)flipY
{
    [[FURenderer shareRenderer] rotateImage:self.rotatedImageManager inPtr:inPtr inFormat:FU_FORMAT_BGRA_BUFFER width:w height:h rotationMode:rotationMode flipX:flipX flipY:flipY];
}

-(CVPixelBufferRef)rotateImage:(CVPixelBufferRef) pixelBuffer rotationMode:(int)rotationMode flipX:(BOOL)flipX flipY:(BOOL)flipY returnNewBuffer:(BOOL)returnNewBuffer
{
    int h = (int)CVPixelBufferGetHeight(pixelBuffer);
    int stride = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
    int w = stride/4;
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void* pod0 = (void *)CVPixelBufferGetBaseAddress(pixelBuffer);
    [self rotateImage:pod0 inFormat:FU_FORMAT_BGRA_BUFFER w:w h:h rotationMode:rotationMode flipX:flipX flipY:flipY];
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    CVPixelBufferRef ret;
    if(returnNewBuffer){
        ret=[self createEmptyPixelBuffer:CGSizeMake((int)CVPixelBufferGetWidth(pixelBuffer), h)];
    } else {
        ret=pixelBuffer;
    }
    CVPixelBufferLockBaseAddress(ret, 0);
    void* pod1 = (void *)CVPixelBufferGetBaseAddress(ret);
    memcpy(pod1, self.rotatedImageManager.mData, w*h*4);
    CVPixelBufferUnlockBaseAddress(ret, 0);
    return ret;
}

#pragma mark ----- 脸部识别
/// 初始化脸部识别
- (void)initFaceCapture
{
    NSData *data = [NSData dataWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"face_capture.bundle" ofType:nil]];
    self.faceCapture = [FURenderer faceCaptureCreate:data.bytes size:(int)data.length];
}

/// 绑定脸部识别到Controller
- (void)bindFaceCaptureToController
{
    [FURenderer itemSetParamu64:self.defalutQController  withName:@"register_face_capture_manager"  value:(unsigned long long)self.faceCapture];
    [FURenderer itemSetParam:self.defalutQController  withName:@"register_face_capture_face_id"  value:@(0.0)];
}

/// 重置脸部识别，切换摄像头时使用
- (void)faceCapureReset
{
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    if (self.faceCapture)
    {
        [FURenderer faceCaptureReset:self.faceCapture];
        dispatch_semaphore_signal(self->signal);
    }
}

/// 销毁脸部识别
- (void)destroyFaceCapture
{
    [FURenderer faceCaptureDestory:self.faceCapture];
    self.faceCapture = nil;
}

/// 是否使用新的人脸驱动模式
/// @param isUse YES为使用，NO为不使用
- (void)useFaceCapure:(BOOL)isUse
{
    self.useFaceCapure = isUse;
    [FURenderer itemSetParam:self.defalutQController withName:@"is_close_dde" value:@(self.useFaceCapure?1.0:0.0)];
    //需要与初值相反
    self.isFaceCaptureEnabled = YES;
    [self enableFaceCapture:!self.isFaceCaptureEnabled];
}

- (void)enableFaceCapture:(BOOL)isEnable
{
    if(self.isFaceCaptureEnabled != isEnable)
    {
        self.isFaceCaptureEnabled = isEnable;
        [FURenderer itemSetParam:self.defalutQController withName:@"close_face_capture" value:@(isEnable?0.0:1.0)];
    }
}

- (void)runFaceCapture:(void*)imagePtr imageFormat:(FUFormat)imageFormat width:(int)width height:(int)height rotateMode:(int)rotateMode
{
    [FURenderer faceCaptureProcessFrame:self.faceCapture inPtr:imagePtr inFormat:imageFormat w:width h:height rotationMode:rotateMode];
}

/// 获取脸部识别识别到的人脸数量
- (int)getFaceCaptureFaceNum
{
    return [FURenderer faceCaptureGetResultFaceNum:self.faceCapture];
}

- (int)getFaceCaptureFaceID:(int)faceIdx
{
    return [FURenderer faceCaptureGetResultFaceID:self.faceCapture faceN:faceIdx];
}

/// 是否识别到人脸
- (int)faceCaptureGetResultIsFace
{
    int num = [FURenderer faceCaptureGetResultIsFace:self.faceCapture faceN:0];
    return num;
}

- (BOOL)isFaceCaptureFace:(int)faceIdx
{
    return [FURenderer faceCaptureGetResultIsFace:self.faceCapture faceN:faceIdx];
}

- (BOOL)getFaceCaptureResult:(FUAvatarInfo*)info faceIdx:(int)faceIdx
{
    if(nil == info)
    {
        return NO;
    }
    [info init];
    
    if(YES == self.useFaceCapure)
    {
        info->isValid= [self isFaceCaptureFace:faceIdx]?1:0;
        if(info->isValid)
        {
#define Get(Func, dst) [FURenderer faceCaptureGetResult##Func:self.faceCapture faceN:faceIdx buffer:info->dst length:sizeof(info->dst)/sizeof(info->dst[0])]
            Get(Landmarks, landmarks);
            Get(Identity, identity);
            Get(Expression, expression);
            Get(Rotation, rotation);
            Get(Translation, translation);
#undef Get
        }
    }
    else
    {
        info->isValid=[FURenderer isTracking];
        if(info->isValid)
        {
#define Get(_name, dst) [FURenderer getFaceInfo:faceIdx name:_name pret:info->dst number:sizeof(info->dst)/sizeof(info->dst[0])]
            Get(@"expression_aligned", expression);
            Get(@"translation_aligned", translation);
            Get(@"rotation_aligned", rotation);
            Get(@"rotation_mode", rotationMode);
            Get(@"pupil_pos", pupilPos);
            Get(@"landmarks", landmarks);
#undef Get
        }
    }
    info->info.is_valid=info->isValid;
    return info->isValid>0;
}

- (BOOL)GetLandmarks:(float*)buff length:(int)length faceIdx:(int)faceIdx
{
    if(YES == self.useFaceCapure)
    {
        if([self getFaceCaptureFaceNum]>0 && [self isFaceCaptureFace:faceIdx])
        {
            [FURenderer faceCaptureGetResultLandmarks:self.faceCapture faceN:faceIdx buffer:buff length:length];
        }
        else
        {
            return NO;
        }
    }
    else
    {
        if([FURenderer isTracking])
        {
            [FURenderer getFaceInfo:faceIdx name:@"landmarks" pret:buff number:length];
        }
        else
        {
            return NO;
        }
    }
    return YES;
}

- (void)trackFace:(CVPixelBufferRef)pixelBuffer
{
    CVPixelBufferLockBaseAddress(pixelBuffer, 0) ;
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) ;
    int height = (int)CVPixelBufferGetHeight(pixelBuffer) ;
    int stride = (int)CVPixelBufferGetBytesPerRow(pixelBuffer) ;
    if(YES == self.useFaceCapure)
    {
        [self runFaceCapture:baseAddress imageFormat:FU_FORMAT_BGRA_BUFFER width:stride/4 height:height rotateMode:0];
    }
    else
    {
        [FURenderer trackFaceWithTongue:FU_FORMAT_BGRA_BUFFER inputData:baseAddress width:stride/4 height:height];
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0) ;
}

- (FUAvatarInfo*)GetAvatarInfo:(CVPixelBufferRef)pixelBuffer renderMode:(FURenderMode)renderMode
{
    FUAvatarInfo* info=[[FUAvatarInfo alloc] init];
    if (renderMode == FURenderPreviewMode)
    {
        [self trackFace:pixelBuffer];
        [self getFaceCaptureResult:info faceIdx:0];
    }
    [self enableFaceCapture:(renderMode == FURenderPreviewMode)];
    return info;
}

#pragma mark ------ 加载道具 ------
/// 加载道具等信息
- (void)loadSubData
{
    switch (self.avatarStyle)
    {
        case FUAvatarStyleNormal:
        {
            if (![[NSFileManager defaultManager] fileExistsAtPath:AvatarListPath])
            {
                [[NSFileManager defaultManager] createDirectoryAtPath:AvatarListPath withIntermediateDirectories:YES attributes:nil error:nil];
            }
//            [self loadNormalTypeSubData];
        }
            break;
        case FUAvatarStyleQ:
        {
            if (![[NSFileManager defaultManager] fileExistsAtPath:AvatarQPath])
            {
                [[NSFileManager defaultManager] createDirectoryAtPath:AvatarQPath withIntermediateDirectories:YES attributes:nil error:nil];
            }
            [self loadQtypeAvatarData];
        }
            break;
    }
}

/// 加载Q版道具数据
- (void)loadQtypeAvatarData
{
    NSMutableArray *itemInfoArray = [NSMutableArray arrayWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"FUQItems.plist" ofType:nil]];
    
    self.itemNameArray = [[NSMutableArray alloc]init];
    self.itemTypeArray = [[NSMutableArray alloc]init];
    self.itemsDict = [[NSMutableDictionary alloc]initWithCapacity:1];
    
    for (int i = 0; i < itemInfoArray.count; i++)
    {
        NSMutableArray *itemArray = [[NSMutableArray alloc]init];
        
        NSDictionary *dictItem = itemInfoArray[i];
        NSString *type = dictItem[@"type"];
        NSArray *paths = dictItem[@"path"];
        
        [self.itemTypeArray addObject:type];
        [self.itemNameArray addObject:dictItem[@"name"]];
        
        if (paths.count == 0)
        {
            continue;
        }
        
        for (int n = 0; n < paths.count; n++)
        {
            NSString *path = paths[n];
            NSString *configPath = [[NSBundle mainBundle].resourcePath stringByAppendingFormat:@"/Resource/%@/config.json",path];
            
            NSData *tmpData = [[NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil] dataUsingEncoding:NSUTF8StringEncoding];
            
            NSMutableDictionary *dic = [NSJSONSerialization JSONObjectWithData:tmpData options:NSJSONReadingMutableContainers error:nil];
            NSArray *itemList = dic[@"list"];
            for (int j = 0; j < itemList.count; j++)
            {
                NSDictionary *item = itemList[j];
                
                if (itemArray.count > 0 && [item[@"icon"] isEqualToString:@"none"])
                {
                    continue;
                }
                
                FUItemModel *itemModel = [[FUItemModel alloc]init];
                itemModel.type = type;
                itemModel.path = [[NSBundle mainBundle].resourcePath stringByAppendingFormat:@"/Resource/%@",path];
                
                [item enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
                    [itemModel setValue:obj forKey:key];
                }];
                
                [itemArray addObject:itemModel];
            }
        }
        
        [self.itemsDict setObject:itemArray forKey:type];
    }
    
    [self loadColorList];
    [self loadMeshPoints];
    [self loadShapeList];
    
    [self loadAvatarList];
}

/// 加载捏脸点位信息
- (void)loadMeshPoints
{
    // mesh points
    NSData *meshData = [[NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"MeshPoints" ofType:@"json"] encoding:NSUTF8StringEncoding error:nil] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *meshDict = [NSJSONSerialization JSONObjectWithData:meshData options:NSJSONReadingMutableContainers error:nil];

    self.qMeshPoints = meshDict[@"mid"] ;
}

/// 加载颜色列表
- (void)loadColorList
{
    // color data
    NSData *jsonData = [[NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"color_q" ofType:@"json"] encoding:NSUTF8StringEncoding error:nil] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *colorDict = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:nil];
    self.colorDict = [[NSMutableDictionary alloc]init];
    
    __block NSMutableDictionary *newColorDict = [[NSMutableDictionary alloc]init];
    
    [colorDict enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        
        NSMutableArray *newTypeColorArray = [[NSMutableArray alloc]init];
        NSMutableDictionary *enumTypeColorDict = (NSMutableDictionary *)obj;

        for (int i = 0 ; i < enumTypeColorDict.allKeys.count; i++)
        {
            NSString *indexKey = [NSString stringWithFormat:@"%d",i+1];
            FUP2AColor *color = [FUP2AColor colorWithDict:[enumTypeColorDict valueForKey:indexKey]];
            
            [newTypeColorArray addObject:color];
        }
        
        [newColorDict setValue:newTypeColorArray forKey:key];
    }];
    
    self.colorDict = newColorDict;
}

/// 加载脸型列表
- (void)loadShapeList
{
    // shape data
    NSData *shapeJson = [[NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"shape_list" ofType:@"json"] encoding:NSUTF8StringEncoding error:nil] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *shapeDict = [NSJSONSerialization JSONObjectWithData:shapeJson options:NSJSONReadingMutableContainers error:nil];
    
    
    for (int i = 0; i < shapeDict.allKeys.count; i++)
    {
        NSString *key = shapeDict.allKeys[i];
        NSArray *array = [shapeDict objectForKey:key];
        
        NSMutableArray *itemArray = [[NSMutableArray alloc]init];

        FUItemModel *nlModel = [[FUItemModel alloc]init];
        nlModel.type = key;
        nlModel.icon =  @"捏脸";
        nlModel.name = @"捏脸";
        [itemArray addObject:nlModel];
        
        for (int n = 0; n < array.count; n++)
        {
            NSMutableDictionary *item = array[n];
            
            FUItemModel *model = [[FUItemModel alloc]init];
            model.type = key;
            model.icon = [item[@"icon"] stringByReplacingOccurrencesOfString:@"icon/PTA_nl" withString:@""];
            model.name = [item[@"icon"] stringByReplacingOccurrencesOfString:@"icon/PTA_nl" withString:@""];
            [item removeObjectForKey:@"icon"];
            model.shapeDict = [item mutableCopy];
            
            [itemArray addObject:model];
        }
        
        [self.itemsDict setObject:itemArray forKey:key];
    }
}

/// 加载形象列表
- (void)loadAvatarList
{
    if (self.avatarList)
    {
        [self.avatarList removeAllObjects];
        self.avatarList = nil ;
    }
    
    if (!self.avatarList)
    {
        self.avatarList = [NSMutableArray arrayWithCapacity:1];
        
        NSData *jsonData = [[NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Avatars" ofType:@"json"] encoding:NSUTF8StringEncoding error:nil] dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *dataArray = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:nil];
        
        for (NSDictionary *dict in dataArray) {
            
            if ([dict[@"q_type"] integerValue] != self.avatarStyle) {
                continue ;
            }
            
            FUAvatar *avatar = [self getAvatarWithInfoDic:dict];
//            [avatar setThePrefabricateColors];
            [self.avatarList addObject:avatar];
        }
        
        NSArray *array = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:AvatarQPath error:nil];
//        self.avatarStyle == FUAvatarStyleNormal ? [[NSFileManager defaultManager] contentsOfDirectoryAtPath:AvatarListPath error:nil] :
        array = [array sortedArrayUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
            return [obj2 compare:obj1 options:NSNumericSearch] ;
        }];
        for (NSString *jsonName in array) {
            if (![jsonName hasSuffix:@".json"]) {
                continue ;
            }
            NSString *jsonPath =  [CurrentAvatarStylePath stringByAppendingPathComponent:jsonName];
            NSData *jsonData = [[NSString stringWithContentsOfFile:jsonPath encoding:NSUTF8StringEncoding error:nil] dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *dic = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingMutableContainers error:nil];
            
            FUAvatar *avatar = [self getAvatarWithInfoDic:dic];
            [self.avatarList addObject:avatar];
        }
    }
}

#pragma mark ------ 设置颜色 ------
/// 设置颜色
/// @param color 颜色模型
/// @param type 颜色类别
- (void)configColorWithColor:(FUP2AColor *)color ofType:(FUFigureColorType)type
{
    NSString *key = [self getColorKeyWithType:type];
    FUAvatar *avatar = [FUManager shareInstance].currentAvatars.firstObject;
    
    BOOL undoOrRedo = [FUAvatarEditManager sharedInstance].undo||[FUAvatarEditManager sharedInstance].redo;
    
    if (!undoOrRedo)
    {
        FUP2AColor *oldColor = [self getSelectedColorWithType:type];
        
        NSMutableDictionary *editDict = [[NSMutableDictionary alloc]init];
        [editDict setObject:color forKey:@"currentConfig"];
        [editDict setObject:oldColor forKey:@"oldConfig"];
        [editDict setObject:[NSNumber numberWithInteger:type] forKey:@"colorType"];
        
        [[FUAvatarEditManager sharedInstance]push:editDict];
    }
    
    [FUAvatarEditManager sharedInstance].undo = NO;
    [FUAvatarEditManager sharedInstance].redo = NO;
    
    [avatar facepupModeSetColor:color key:key];
    
    NSInteger index = [self.colorDict[key] indexOfObject:color];
    [self setSelectColorIndex:index ofType:type];
}


/// 配置肤色
/// @param progress 颜色进度
/// @param isPush 是否加入撤销的堆栈
- (void)configSkinColorWithProgress:(double)progress isPush:(BOOL)isPush
{
    FUAvatar *avatar = [FUManager shareInstance].currentAvatars.firstObject;
    
    BOOL undoOrRedo = [FUAvatarEditManager sharedInstance].undo||[FUAvatarEditManager sharedInstance].redo;
    
    FUP2AColor *newColor = [self getSkinColorWithProgress:progress];
    
    if (!undoOrRedo && isPush)
    {
        double oldeSkinColorProgress = avatar.skinColorProgress;
        FUP2AColor *oldColor = [self getSkinColorWithProgress:oldeSkinColorProgress];
        
        NSMutableDictionary *editDict = [[NSMutableDictionary alloc]init];
        [editDict setObject:newColor forKey:@"currentConfig"];
        [editDict setObject:oldColor forKey:@"oldConfig"];
        [editDict setObject:[NSNumber numberWithDouble:oldeSkinColorProgress] forKey:@"oldSkinColorProgress"];
        [editDict setObject:[NSNumber numberWithDouble:progress] forKey:@"skinColorProgress"];
        [editDict setObject:[NSNumber numberWithInteger:FUFigureColorTypeSkinColor] forKey:@"colorType"];
        
        [[FUAvatarEditManager sharedInstance]push:editDict];
    }

    [FUAvatarEditManager sharedInstance].undo = NO;
    [FUAvatarEditManager sharedInstance].redo = NO;

    [avatar facepupModeSetColor:newColor key:[self getColorKeyWithType:FUFigureColorTypeSkinColor]];

    [self setSelectColorIndex:0 ofType:FUFigureColorTypeSkinColor];
}

#pragma mark ------ 绑定道具 ------
/// 绑定道具
/// @param model 道具相关信息
- (void)bindItemWithModel:(FUItemModel *)model
{
    FUAvatar *avatar = [FUManager shareInstance].currentAvatars.firstObject;
    BOOL undoOrRedo = [FUAvatarEditManager sharedInstance].undo||[FUAvatarEditManager sharedInstance].redo;
    
    if ([model.type isEqualToString:TAG_FU_ITEM_HAIR])
    {
        [avatar bindHairWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_FACE])
    {
        if ([model.name isEqualToString:@"捏脸"]&&!undoOrRedo)
        {
            self.shapeModeKey = [model.type stringByAppendingString:@"_front"];
            [[NSNotificationCenter defaultCenter] postNotificationName:FUEnterNileLianNot object:nil];
            return;
        }
        else
        {
            [avatar configFacepupParamWithDict:model.shapeDict];
        }
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_MOUTH])
    {
        if ([model.name isEqualToString:@"捏脸"]&&!undoOrRedo)
        {
            self.shapeModeKey = [model.type stringByAppendingString:@"_front"];
            [[NSNotificationCenter defaultCenter] postNotificationName:FUEnterNileLianNot object:nil];
            return;
        }
        else
        {
            [avatar configFacepupParamWithDict:model.shapeDict];
        }
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_EYE])
    {
        if ([model.name isEqualToString:@"捏脸"]&&!undoOrRedo)
        {
            self.shapeModeKey = [model.type stringByAppendingString:@"_front"];
            [[NSNotificationCenter defaultCenter] postNotificationName:FUEnterNileLianNot object:nil];
            return;
        }
        else
        {
            [avatar configFacepupParamWithDict:model.shapeDict];
        }
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_NOSE])
    {
        if ([model.name isEqualToString:@"捏脸"]&&!undoOrRedo)
        {
            self.shapeModeKey = [model.type stringByAppendingString:@"_front"];
            [[NSNotificationCenter defaultCenter] postNotificationName:FUEnterNileLianNot object:nil];
            return;
        }
        else
        {
            [avatar configFacepupParamWithDict:model.shapeDict];
        }
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_CLOTH])
    {
        self.isBindCloths = YES;
        [avatar bindClothWithItemModel:model];
        
        [self.selectedItemIndexDict setObject:@(0) forKey:TAG_FU_ITEM_UPPER];
        [self.selectedItemIndexDict setObject:@(0) forKey:TAG_FU_ITEM_LOWER];
        
        self.isBindCloths = NO;
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_UPPER])
    {
        self.isBindCloths = YES;
        if (avatar.clothType == FUAvataClothTypeSuit)
        {
            FUItemModel *lowerModel = [FUManager shareInstance].itemsDict[TAG_FU_ITEM_LOWER][1];
            [avatar bindLowerWithItemModel:lowerModel];
            [self.selectedItemIndexDict setObject:@(0) forKey:TAG_FU_ITEM_CLOTH];
            [self.selectedItemIndexDict setObject:@(1) forKey:TAG_FU_ITEM_LOWER];
        }
        [avatar bindUpperWithItemModel:model];
        self.isBindCloths = NO;
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_LOWER])
    {
        self.isBindCloths = YES;
        if (avatar.clothType == FUAvataClothTypeSuit)
        {
            FUItemModel *upperModel = [FUManager shareInstance].itemsDict[TAG_FU_ITEM_UPPER][1];
            [avatar bindUpperWithItemModel:upperModel];
            [self.selectedItemIndexDict setObject:@(0) forKey:TAG_FU_ITEM_CLOTH];
            [self.selectedItemIndexDict setObject:@(1) forKey:TAG_FU_ITEM_UPPER];
        }
        [avatar bindLowerWithItemModel:model];
        self.isBindCloths = NO;
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_SHOES])
    {
        [avatar bindShoesWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_HAT])
    {
        [avatar bindHatWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_EYELASH])
    {
        [avatar bindEyeLashWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_EYEBROW])
    {
        [avatar bindEyebrowWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_BEARD])
    {
        [avatar bindBeardWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_GLASSES])
    {
        [avatar bindGlassesWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_EYESHADOW])
    {
        [avatar bindEyeShadowWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_EYELINER])
    {
        [avatar bindEyeLinerWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_PUPIL])
    {
        [avatar bindPupilWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_FACEMAKEUP])
    {
        [avatar bindFaceMakeupWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_LIPGLOSS])
    {
        [avatar bindLipGlossWithItemModel:model];
    }
    else if ([model.type isEqualToString:TAG_FU_ITEM_DECORATION])
    {
        [avatar bindDecorationWithItemModel:model];
    }
    
    //设置undo堆栈
    if (!undoOrRedo)
    {
        NSMutableDictionary *editDict = [[NSMutableDictionary alloc]init];
        
        FUItemModel *oldModel = [avatar valueForKey:model.type];
        if ([oldModel.name isEqualToString:@"捏脸"]&&!oldModel.shapeDict)
        {
            [[FUShapeParamsMode shareInstance]getOrignalParamsWithAvatar:self.currentAvatars.firstObject];
            oldModel.shapeDict = [FUShapeParamsMode shareInstance].orginalFaceup;
        }
        editDict[@"oldConfig"] = oldModel;
        editDict[@"currentConfig"] = model;
        
        [[FUAvatarEditManager sharedInstance]push:editDict];
    }
    
    [FUAvatarEditManager sharedInstance].undo = NO;
    [FUAvatarEditManager sharedInstance].redo = NO;

    //设置选中索引
    NSArray *array = self.itemsDict[model.type];
    NSInteger index = [array containsObject:model]?[array indexOfObject:model]:0;

    [self.selectedItemIndexDict setObject:@(index) forKey:model.type];
    
    //修改模型信息的参数
    [avatar setValue:model forKey:model.type];
}


#pragma mark ------ 背景 ------
/// 加载默认背景
- (void)loadDefaultBackGroundToController
{
    NSString *default_bg_Path = [[NSBundle mainBundle] pathForResource:@"default_bg" ofType:@"bundle"];
    [self rebindItemToControllerWithFilepath:default_bg_Path withPtr:&q_controller_bg_ptr];
}

/// 绑定背景道具到controller
/// @param filePath 新背景道具路径
- (void)reloadBackGroundAndBindToController:(NSString *)filePath
{
    [self rebindItemToControllerWithFilepath:filePath withPtr:&q_controller_bg_ptr];
}

#pragma mark ------ hair_mask ------
/**
 绑定hair_mask.bundle
 */
- (void)bindHairMask
{
    NSString *hair_mask_Path = [[NSBundle mainBundle] pathForResource:@"hair_mask.bundle" ofType:nil];
    hair_mask_ptr = [self bindItemToControllerWithFilepath:hair_mask_Path];
}

/**
 销毁hair_mask.bundle
 */
- (void)destoryHairMask
{
    if (hair_mask_ptr > 0)
    {
        // 解绑
        [FURenderer unBindItems:self.defalutQController items:&hair_mask_ptr itemsCount:1];
        // 销毁
        [FURenderer destroyItem:hair_mask_ptr];
    }
}

#pragma mark ------ Cam ------
/**
 更新Cam道具
 
 @param camPath 辅助道具路径
 */
- (void)reloadCamItemWithPath:(NSString *)camPath
{
    [self rebindItemToControllerWithFilepath:camPath withPtr:&q_controller_cam];
}

#pragma mark ------ 绑定底层方法 ------
/// 重新绑定道具
/// @param filePath 新的道具路径
/// @param ptr 道具句柄
- (void)rebindItemToControllerWithFilepath:(NSString *)filePath withPtr:(int *)ptr
{
    if (*ptr > 0)
    {
        // 解绑并销毁旧道具
        [FURenderer unBindItems:self.defalutQController items:ptr itemsCount:1];
        [FURenderer destroyItem:*ptr];
    }
    //绑定新道具
    *ptr = [self bindItemToControllerWithFilepath:filePath];
    
}

/// 绑定道具
/// @param filePath 道具路径
- (int)bindItemToControllerWithFilepath:(NSString *)filePath
{
    int tmpHandle = [FURenderer itemWithContentsOfFile:filePath];
    [FURenderer bindItems:self.defalutQController items:&tmpHandle itemsCount:1];
    return tmpHandle;
}

#pragma mark ------ 形象数据处理 ------

/// 进入编辑模式
- (void)enterEditMode
{
    self.itemTypeSelectIndex = 0;
    [self getSelectedInfo];
    [self recordItemBeforeEdit];
}

/// 获取当前形象的道具和颜色选中情况
- (void)getSelectedInfo
{
    self.selectedItemIndexDict = [self getSelectedItemIndexDictWithAvatar:self.currentAvatars.lastObject];
    self.selectedColorDict = [self getSelectedColorIndexDictWithAvatar:self.currentAvatars.lastObject];
}

/// 记录编辑前的形象信息
- (void)recordItemBeforeEdit
{
    self.beforeEditAvatar = [self.currentAvatars.firstObject copy];
}

/// 将形象信息恢复到编辑前
- (void)reloadItemBeforeEdit
{
    [self.currentAvatars.firstObject resetValueFromBeforeEditAvatar:self.beforeEditAvatar];
    [self.currentAvatars.firstObject loadAvatarToController];
}

/// 判断形象是否编辑过
- (BOOL)hasEditAvatar
{
    __block BOOL hasChanged = NO;
    
    [self.selectedItemIndexDict enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
       
        FUAvatar *avatar = self.beforeEditAvatar;
        
        FUItemModel *selectedModel = [self.itemsDict[key] objectAtIndex:[obj integerValue]];
        
        if (![selectedModel isEqual:[avatar valueForKey:key]])
        {
            hasChanged = YES;
            *stop = YES;
        }
    }];
    
    if (hasChanged)
    {
        return hasChanged;
    }
    
    NSMutableDictionary *selectedColorIndexDict_beforeEdit = [self getSelectedColorIndexDictWithAvatar:self.beforeEditAvatar];
    
    [self.selectedColorDict enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
       
        NSInteger index = [selectedColorIndexDict_beforeEdit[key] integerValue];
        
        if (index != [obj integerValue] && ![key isEqualToString:@"skin_color"])
        {
            hasChanged = YES;
            *stop = YES;
        }
    }];
    
    if (hasChanged)
    {
        return hasChanged;
    }
    
    
    if (![[NSNumber numberWithDouble:self.beforeEditAvatar.skinColorProgress] isEqualToNumber: [NSNumber numberWithDouble:self.currentAvatars.firstObject.skinColorProgress]])
    {
        return YES;
    }
    
    
    return hasChanged;
}

- (BOOL)faceHasChanged
{
    BOOL change = NO;
    if (self.beforeEditAvatar.face == self.currentAvatars.firstObject.face)
    {
        return YES;
    }
    
    if (self.beforeEditAvatar.eyes == self.currentAvatars.firstObject.eyes)
    {
        return YES;
    }
    
    if (self.beforeEditAvatar.mouth == self.currentAvatars.firstObject.mouth)
    {
        return YES;
    }
    
    if (self.beforeEditAvatar.nose == self.currentAvatars.firstObject.nose)
    {
        return YES;
    }
    
    return change;
}

//如果是预制形象生成新的形象，如果不是预制模型保存新的信息
- (void)saveAvatar
{
    FUAvatar *currentAvatar = self.currentAvatars.lastObject;
    BOOL deformHead = [[FUShapeParamsMode shareInstance]propertiesIsChanged]||[self faceHasChanged];
    
    //获取保存形象的名字
    NSString *avatarName = currentAvatar.defaultModel ? [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]] : currentAvatar.name;
    
    //获取文件路径
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *filePath = [documentPath stringByAppendingPathComponent:avatarName];
    
    if (![fileManager fileExistsAtPath:filePath])
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:filePath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    //拷贝head.bundle,如果需要重新生成头拷贝新的head.bundle
    NSData *headData = [NSData dataWithContentsOfFile:[[currentAvatar filePath] stringByAppendingPathComponent:FU_HEAD_BUNDLE]];
    if (deformHead)
    {//deformHead 决定是否生成新头
        NSArray *params = [[FUShapeParamsMode shareInstance]getShapeParamsWithAvatar:self.currentAvatars.firstObject];
        
        float coeffi[100];
        for (int i = 0 ; i < 100; i ++)
        {
            coeffi[i] = [params[i] floatValue];
        }
        //重新生成head.bundle
        headData = [[fuPTAClient shareInstance] deformHeadWithHeadData:headData deformParams:coeffi paramsSize:100 withExprOnly:NO withLowp:NO].bundle;
    }
    [headData writeToFile:[filePath stringByAppendingPathComponent:@"/head.bundle"] atomically:YES];
    
    if (deformHead)
    {
        [currentAvatar bindItemWithType:FUItemTypeHead filePath:[filePath stringByAppendingPathComponent:@"/head.bundle"]];
    }

    if (currentAvatar.defaultModel)
    {//如果是预制模型，拷贝头像
        UIImage *image = [UIImage imageWithContentsOfFile:currentAvatar.imagePath];
        NSData *imageData = UIImageJPEGRepresentation(image, 1.0) ;
        [imageData writeToFile:[filePath stringByAppendingString:@"/image.png"] atomically:YES];
    }
    
    //获取并写入数据json
    NSMutableDictionary *avatarDict = [[NSMutableDictionary alloc]init];
    [avatarDict setValue:avatarName forKey:@"name"];
    [avatarDict setValue:@(currentAvatar.gender) forKey:@"gender"];
    [avatarDict setValue:@(0) forKey:@"default"];
    [avatarDict setValue:@(1) forKey:@"q_type"];
    [avatarDict setValue:@(currentAvatar.clothType) forKey:@"clothType"];
    [avatarDict setValue:@(currentAvatar.skinColorProgress) forKey:TAG_FU_SKIN_COLOR_PROGRESS];

    [self.selectedItemIndexDict enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {

        NSArray *itemArray = self.itemsDict[key];
        FUItemModel *model = [itemArray objectAtIndex:[obj integerValue]];

        if (!currentAvatar.defaultModel)
        {
            [currentAvatar setValue:model forKey:key];
        }

        [avatarDict setValue:model.name forKey:key];
    }];

    [self.selectedColorDict enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {

        NSString *colorIndexKey = [key stringByReplacingOccurrencesOfString:@"_c" withString:@"C"];
        colorIndexKey = [colorIndexKey stringByReplacingOccurrencesOfString:@"_f" withString:@"F"];
        colorIndexKey = [colorIndexKey stringByAppendingString:@"Index"];

        [avatarDict setValue:[NSNumber numberWithInteger:[obj integerValue]] forKey:colorIndexKey];
        [currentAvatar setValue:[NSNumber numberWithInteger:[obj integerValue]] forKey:colorIndexKey];
    }];

    NSData *avatarData = [NSJSONSerialization dataWithJSONObject:avatarDict options:NSJSONWritingPrettyPrinted error:nil];
    NSString *jsonPath = [[CurrentAvatarStylePath stringByAppendingPathComponent:avatarName] stringByAppendingString:@".json"];

    [avatarData writeToFile:jsonPath atomically:YES];
    
    //defaultModel 决定是否生成新的形象
    if (currentAvatar.defaultModel)
    {
        FUAvatar *newAvatar = [self getAvatarWithInfoDic:avatarDict];
        
        ///拷贝头发
        BOOL shouldDeformHair = [[FUShapeParamsMode shareInstance]shouldDeformHair];
        
        if (shouldDeformHair)
        {
            [self createAndCopyHairBundlesWithAvatar:newAvatar withHairModel:newAvatar.hair];
        }
        else
        {
            for (FUItemModel *model in self.itemsDict[TAG_FU_ITEM_HAIR])
            {
                if ([model.name rangeOfString:@"noitem"].length > 0)
                {
                    continue ;
                }

                NSString *hairSource = [NSString stringWithFormat:@"%@/%@",model.path,model.bundle];
                if ([fileManager fileExistsAtPath:hairSource])
                {
                    [fileManager copyItemAtPath:hairSource toPath:[filePath stringByAppendingPathComponent:model.name] error:nil];
                }
            }
        }
        
        [[FUManager shareInstance].avatarList insertObject:newAvatar atIndex:DefaultAvatarNum];
        [currentAvatar resetValueFromBeforeEditAvatar:self.beforeEditAvatar];
        [currentAvatar quitFacepupMode];
        [[FUManager shareInstance] reloadAvatarToControllerWithAvatar:newAvatar];
    }
    else
    {
        [self.currentAvatars.firstObject quitFacepupMode];
        [self.currentAvatars.firstObject loadAvatarColor];
        ///拷贝头发
        BOOL shouldDeformHair = [[FUShapeParamsMode shareInstance]shouldDeformHair];
        
        if (shouldDeformHair)
        {
            [self createAndCopyHairBundlesWithAvatar:self.currentAvatars.firstObject withHairModel:self.currentAvatars.firstObject.hair];
        }
    }
}



#pragma mark ------ 道具编辑相关 ------
/// 获取当前选中的道具类别
- (NSString *)getSelectedType
{
    if ([FUManager shareInstance].itemTypeSelectIndex < 0)
    {
        [FUManager shareInstance].itemTypeSelectIndex = 0;
    }
    
    return [FUManager shareInstance].itemTypeArray[[FUManager shareInstance].itemTypeSelectIndex];
}


/// 获取当前类别的捏脸model
- (FUItemModel *)getNieLianModelOfSelectedType
{
    NSArray *array = [self getItemArrayOfSelectedType];
    
    FUItemModel *model = array[0];
    
    return model;
}

/// 获取当前类别选中的道具编号
- (NSInteger)getSelectedItemIndexOfSelectedType
{
    NSString *type = [self getSelectedType];
    
    if (!self.selectedItemIndexDict)
    {
        [self getSelectedItemIndexDictWithAvatar:self.currentAvatars.lastObject];
    }
    
    NSInteger index = [[self.selectedItemIndexDict objectForKey:type] integerValue];
    
    return index;
}

/// 设置选中道具编号
/// @param index 道具编号
- (void)setSelectedItemIndex:(NSInteger)index
{
    NSString *type = [self getSelectedType];
    [self.selectedItemIndexDict setValue:@(index) forKey:type];
}

/// 获取当前类别的道具数组
- (NSArray *)getItemArrayOfSelectedType
{
    if ([FUManager shareInstance].itemTypeSelectIndex == -1)
    {
        return [[NSArray alloc] init];
    }
    NSString *type = [self getSelectedType];
    NSArray *array = [FUManager shareInstance].itemsDict[type];
    
    return array;
}

/// 获取道具选中字典
/// @param avatar 形象模型
- (NSMutableDictionary *)getSelectedItemIndexDictWithAvatar:(FUAvatar *)avatar
{
    NSMutableDictionary *selectedItemIndexDict = [[NSMutableDictionary alloc]init];
    
    [self.itemTypeArray enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        
        FUItemModel *model = [avatar valueForKey:obj];
        NSArray *modelArray = self.itemsDict[obj];
        
        NSInteger index = [modelArray containsObject:model]?[modelArray indexOfObject:model]:0;
        
        [selectedItemIndexDict setObject:@(index) forKey:obj];
    }];
    
    return selectedItemIndexDict;
}

/// 获取颜色选中字典
/// @param avatar 形象模型
- (NSMutableDictionary *)getSelectedColorIndexDictWithAvatar:(FUAvatar *)avatar
{
    NSMutableDictionary *selectedColorDict = [[NSMutableDictionary alloc]init];
    
    for (int i = 0; i < FUFigureColorTypeEnd; i++)
    {
        NSString *key = [[FUManager shareInstance]getColorKeyWithType:(FUFigureColorType)i];
        
        NSString *indexProKey = [key stringByReplacingOccurrencesOfString:@"_c" withString:@"C"];
        indexProKey = [indexProKey stringByReplacingOccurrencesOfString:@"_f" withString:@"F"];
        indexProKey = [indexProKey stringByAppendingString:@"Index"];
        
        NSInteger index = [[avatar valueForKey:indexProKey] integerValue];
        
        [selectedColorDict setValue:@(index) forKey:key];
    }
    
    return selectedColorDict;
}


#pragma mark ------ 颜色编辑相关 ------
- (FUP2AColor *)getSkinColorWithProgress:(double)progress
{
    NSInteger colorsCount = [[FUManager shareInstance] getColorArrayCountWithType:FUFigureColorTypeSkinColor];
    double step = 1.0/(colorsCount - 1);
    
    double colorIndexDouble = progress / step;
    int colorIndex = colorIndexDouble;
    
    FUP2AColor * baseColor = [[FUManager shareInstance] getColorWithType:FUFigureColorTypeSkinColor andIndex:colorIndex];
    
    UIColor * newColor;
    
    if (colorIndex >= colorsCount - 1)
    {
        newColor = baseColor.color;
    }
    else
    {
        FUP2AColor * nextColor = [[FUManager shareInstance] getColorWithType:FUFigureColorTypeSkinColor andIndex:colorIndex+1];
        double RStep = (nextColor.r - baseColor.r);
        double GStep = (nextColor.g - baseColor.g);
        double BStep = (nextColor.b - baseColor.b);
        double colorInterval = colorIndexDouble - colorIndex;
        newColor = [UIColor colorWithRed:(baseColor.r + RStep * colorInterval)/ 255.0 green:(baseColor.g + GStep * colorInterval)/ 255.0 blue:(baseColor.b + BStep * colorInterval)/ 255.0 alpha:1];
    }
    
    return [FUP2AColor color:newColor];
}

/// 根据类别获取选中的颜色编号
/// @param type 颜色类别
- (NSInteger)getSelectedColorIndexWithType:(FUFigureColorType)type
{
    return [[self.selectedColorDict objectForKey:[self getColorKeyWithType:type]] intValue]-1;
}

/// 根据类别获取选中的颜色
- (FUP2AColor *)getSelectedColorWithType:(FUFigureColorType)type
{
    NSArray *selectedColorArray = self.colorDict[[self getColorKeyWithType:type]];
    NSInteger index = [[self.selectedColorDict objectForKey:[self getColorKeyWithType:type]] intValue]-1;
    FUP2AColor *color = [selectedColorArray objectAtIndex:index];
    
    return color;
}

/// 设置对应类别的选中颜色编号
/// @param index 选中的颜色编号
/// @param type 颜色类别
- (void)setSelectColorIndex:(NSInteger)index ofType:(FUFigureColorType)type
{
    [self.selectedColorDict setValue:@(index+1) forKey:[self getColorKeyWithType:type]];
}

/// 根据类别获取对应颜色数组的长度
/// @param type 颜色类别
- (NSInteger)getColorArrayCountWithType:(FUFigureColorType)type
{
    NSArray *array = self.colorDict[[self getColorKeyWithType:type]];

    return array.count;
}

/// 根据类别获取对应颜色数组
/// @param type 颜色类别
- (NSArray *)getColorArrayWithType:(FUFigureColorType)type
{
    return self.colorDict[[self getColorKeyWithType:type]];
}

/// 根据颜色类别获取颜色类别关键字
/// @param type 颜色类别
- (NSString *)getColorKeyWithType:(FUFigureColorType)type
{
    NSString *key;
    
    switch (type)
    {
        case FUFigureColorTypeSkinColor:
            key = @"skin_color";
            break;
        case FUFigureColorTypeLipsColor:
            key = @"lip_color";
            break;
        case FUFigureColorTypeirisColor:
            key = @"iris_color";
            break;
        case FUFigureColorTypeHairColor:
            key = @"hair_color";
            break;
        case FUFigureColorTypeBeardColor:
            key = @"beard_color";
            break;
        case FUFigureColorTypeGlassesFrameColor:
            key = @"glass_frame_color";
            break;
        case FUFigureColorTypeGlassesColor:
            key = @"glass_color";
            break;
        case FUFigureColorTypeHatColor:
            key = @"hat_color";
            break;
        default:
            break;
    }
    
    return key;
}

/// 获取颜色模型
/// @param type 颜色类别
/// @param index 颜色编号
- (FUP2AColor *)getColorWithType:(FUFigureColorType)type andIndex:(NSInteger)index
{
    FUP2AColor *color = [[self getColorArrayWithType:type]objectAtIndex:index];
    
    return color;
}


#pragma mark  ------ 生成形象 ------
/// 根据形象信息字典生成形象模型
/// @param dict 形象信息字典
- (FUAvatar *)getAvatarWithInfoDic:(NSDictionary *)dict
{
    FUAvatar *avatar = [[FUAvatar alloc] init];
    
    avatar.name = dict[@"name"];
    avatar.gender = (FUGender)[dict[@"gender"] intValue];
    avatar.defaultModel = [dict[@"default"] boolValue];
    
    avatar.isQType = [dict[@"q_type"] integerValue];
    avatar.clothType = (FUAvataClothType)[dict[@"clothType"] integerValue];
    
    avatar.clothes = [self getItemModelWithKey:TAG_FU_ITEM_CLOTH andDict:dict];
    avatar.upper = [self getItemModelWithKey:TAG_FU_ITEM_UPPER andDict:dict];
    avatar.lower = [self getItemModelWithKey:TAG_FU_ITEM_LOWER andDict:dict];
    avatar.hair = [self getItemModelWithKey:TAG_FU_ITEM_HAIR andDict:dict];
    avatar.face = [self getItemModelWithKey:TAG_FU_ITEM_FACE andDict:dict];
    avatar.eyes = [self getItemModelWithKey:TAG_FU_ITEM_EYE andDict:dict];
    avatar.mouth = [self getItemModelWithKey:TAG_FU_ITEM_MOUTH andDict:dict];
    avatar.nose = [self getItemModelWithKey:TAG_FU_ITEM_NOSE andDict:dict];
    avatar.shoes = [self getItemModelWithKey:TAG_FU_ITEM_SHOES andDict:dict];
    avatar.hat = [self getItemModelWithKey:TAG_FU_ITEM_HAT andDict:dict];
    avatar.eyeLash = [self getItemModelWithKey:TAG_FU_ITEM_EYELASH andDict:dict];
    avatar.eyeBrow = [self getItemModelWithKey:TAG_FU_ITEM_EYEBROW andDict:dict];
    avatar.beard = [self getItemModelWithKey:TAG_FU_ITEM_BEARD andDict:dict];
    avatar.glasses = [self getItemModelWithKey:TAG_FU_ITEM_GLASSES andDict:dict];
    avatar.eyeShadow = [self getItemModelWithKey:TAG_FU_ITEM_EYESHADOW andDict:dict];
    avatar.eyeLiner = [self getItemModelWithKey:TAG_FU_ITEM_EYELINER andDict:dict];
    avatar.pupil = [self getItemModelWithKey:TAG_FU_ITEM_PUPIL andDict:dict];
    avatar.faceMakeup = [self getItemModelWithKey:TAG_FU_ITEM_FACEMAKEUP andDict:dict];
    avatar.lipGloss = [self getItemModelWithKey:TAG_FU_ITEM_LIPGLOSS andDict:dict];
    avatar.decorations = [self getItemModelWithKey:TAG_FU_ITEM_DECORATION andDict:dict];
    
    avatar.skinColorIndex = [self getIndexWithColorTypeKey:@"skin" andDict:dict];
    avatar.lipColorIndex = [self getIndexWithColorTypeKey:@"lip" andDict:dict];
    avatar.irisColorIndex = [self getIndexWithColorTypeKey:@"iris" andDict:dict];
    avatar.hairColorIndex = [self getIndexWithColorTypeKey:@"hair" andDict:dict];
    avatar.beardColorIndex = [self getIndexWithColorTypeKey:@"beard" andDict:dict];
    avatar.glassFrameColorIndex = [self getIndexWithColorTypeKey:@"glassFrame" andDict:dict] ;
    avatar.glassColorIndex = [self getIndexWithColorTypeKey:@"glass" andDict:dict];
    avatar.hatColorIndex = [self getIndexWithColorTypeKey:@"hat" andDict:dict];
    avatar.skinColorProgress = [dict[TAG_FU_SKIN_COLOR_PROGRESS] doubleValue];
    
    return avatar;
}

/**
 Avatar 生成
 
 @param data    服务端拉流数据
 @param name    Avatar 名字
 @param gender  Avatar 性别
 @return        生成的 Avatar
 */
- (FUAvatar *)createAvatarWithData:(NSData *)data avatarName:(NSString *)name gender:(FUGender)gender {
    
    isCreatingAvatar = YES;
    
    FUAvatar *avatar = [[FUAvatar alloc] init];
    avatar.defaultModel = NO;
    avatar.name = name;
    avatar.gender = gender;
    avatar.isQType = self.avatarStyle == FUAvatarStyleQ;
    
    
    [data writeToFile:[[avatar filePath] stringByAppendingPathComponent:FU_HEAD_BUNDLE] atomically:YES];
    [[fuPTAClient shareInstance] setHeadData:data];
    // 头发
    int hairLabel = [[fuPTAClient shareInstance] getInt:@"hair_label"];
    avatar.hairLabel = hairLabel;
    FUItemModel *defaultHairModel = [self gethairNameWithNum:hairLabel andGender:gender];
    avatar.hair = defaultHairModel;
    
    NSString *baseHairPath = [NSString stringWithFormat:@"%@/%@",defaultHairModel.path,defaultHairModel.bundle];
    NSData *baseHairData = [NSData dataWithContentsOfFile:baseHairPath];
    NSData *defaultHairData = [[fuPTAClient shareInstance] createHairWithHeadData:data defaultHairData:baseHairData];
    NSString *defaultHairPath = [[avatar filePath] stringByAppendingPathComponent:avatar.hair.name];
    
    [defaultHairData writeToFile:defaultHairPath atomically:YES];
    [[fuPTAClient shareInstance] setHeadData:data];
    // 眼镜
    int hasGlass = [[fuPTAClient shareInstance] getInt:@"has_glasses"];
    //    avatar.glasses = hasGlass == 0 ? @"glasses-noitem" : (gender == FUGenderMale ? @"male_glass_1" : @"female_glass_1");
    if (hasGlass == 0)
    {
        avatar.glasses = self.itemsDict[TAG_FU_ITEM_GLASSES][0];
    }
    else
    {
        int shapeGlasses = [[fuPTAClient shareInstance] getInt:@"shape_glasses"];
        int rimGlasses = [[fuPTAClient shareInstance] getInt:@"rim_glasses"];
        if (avatar.isQType)
        {
            NSLog(@"---------Q-Style--- shape_glasses: %d - rim_glasses:%d", shapeGlasses, rimGlasses);
            avatar.glasses = [self getQGlassesNameWithShape:shapeGlasses rim:rimGlasses male:gender == FUGenderMale];
        }
        else
        {

            NSLog(@"--------- shape_glasses: %d - rim_glasses:%d", shapeGlasses, rimGlasses);
            avatar.glasses = [self getGlassesNameWithShape:shapeGlasses rim:rimGlasses male:gender == FUGenderMale];
        }
    }
    
    avatar.hat = self.itemsDict[TAG_FU_ITEM_UPPER][0];
    
    // avatar info
    NSMutableDictionary *avatarInfo = [NSMutableDictionary dictionaryWithCapacity:1];
    NSArray *upperArray = self.itemsDict[TAG_FU_ITEM_UPPER];
    for (int i = 1; i < upperArray.count; i++)
    {
        FUItemModel *upperModel = upperArray[i];
                   
        if ([upperModel.gender integerValue] == avatar.gender)
        {
            avatar.upper = upperModel;
            break;
        }
    }
    avatar.wearFemaleClothes = avatar.gender;
    avatar.lower = self.itemsDict[TAG_FU_ITEM_LOWER][1];
    avatar.shoes = self.itemsDict[TAG_FU_ITEM_SHOES][7];
    avatar.clothes = self.itemsDict[TAG_FU_ITEM_CLOTH][0];
    avatar.clothType = FUAvataClothTypeUpperAndLower;
    
    // 胡子
    
    int beardLabel = [[fuPTAClient shareInstance] getInt:@"beard_label"];
    avatar.bearLabel = beardLabel;
    avatar.beard = [self getBeardNameWithNum:beardLabel Qtype:avatar.isQType male:avatar.gender == FUGenderMale];

    [avatarInfo setObject:@(0) forKey:@"default"];
    [avatarInfo setObject:@(avatar.isQType) forKey:@"q_type"];
    [avatarInfo setObject:name forKey:@"name"];
    [avatarInfo setObject:@(gender) forKey:@"gender"];

    [avatarInfo setObject:@(hairLabel) forKey:@"hair_label"];
    [avatarInfo setObject:avatar.hair.name forKey:@"hair"];
    [avatarInfo setObject:@(beardLabel) forKey:@"beard_label"];
    [avatarInfo setObject:avatar.beard.name forKey:@"beard"];
    
    [avatarInfo setObject:@(avatar.clothType) forKey:@"clothType"];
    [avatarInfo setObject:avatar.upper.name forKey:@"upper"];
    [avatarInfo setObject:avatar.lower.name forKey:@"lower"];
    [avatarInfo setObject:avatar.shoes.name forKey:@"shoes"];
    [avatarInfo setObject:avatar.hat.name forKey:@"hat"];
    [avatarInfo setObject:avatar.clothes.name forKey:@"clothes"];
    [avatarInfo setObject:avatar.glasses.name forKey:@"glasses"];
    
    [avatarInfo setObject:@(0.3) forKey:@"skin_color_progress"];
    
    NSString *avatarInfoPath = [[CurrentAvatarStylePath stringByAppendingPathComponent:avatar.name] stringByAppendingString:@".json"];
    NSData *avatarInfoData = [NSJSONSerialization dataWithJSONObject:avatarInfo options:NSJSONWritingPrettyPrinted error:nil];
    [avatarInfoData writeToFile:avatarInfoPath atomically:YES];
    appManager.localizeHairBundlesSuccess = false;
    
    [[fuPTAClient shareInstance] releaseHeadData];
    
    FUAvatar *newAvatar = [self getAvatarWithInfoDic:avatarInfo];
    [self createAndCopyHairBundlesWithAvatar:newAvatar withHairModel:avatar.hair];
    
    return newAvatar;
}

/// 生成并复制头发到形象目录
/// @param avatar 形象模型
- (void)createAndCopyHairBundlesWithAvatar:(FUAvatar *)avatar withHairModel:(FUItemModel *)model
{
    NSString *headPath = [avatar.filePath stringByAppendingPathComponent:FU_HEAD_BUNDLE];
    NSData *headData = [NSData dataWithContentsOfFile:headPath];
    
    //获取文件路径
    NSString *filePath = [documentPath stringByAppendingPathComponent:avatar.name];
    
    NSString *hairPath = [model.path stringByAppendingPathComponent:model.bundle];
    NSData *hairData = [NSData dataWithContentsOfFile:hairPath];
    
    if (hairData != nil)
    {
        NSData *newHairData = [[fuPTAClient shareInstance]createHairWithHeadData:headData defaultHairData:hairData];
        NSString *newHairPath = [filePath stringByAppendingPathComponent:model.name];
        
        [newHairData writeToFile:newHairPath atomically:YES];
    }
}

/// 生成并复制头发到形象目录
/// @param avatar 形象模型
- (void)createAndCopyAllHairBundlesWithAvatar:(FUAvatar *)avatar
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *hairArray = self.itemsDict[TAG_FU_ITEM_HAIR];
        NSString *headPath = [avatar.filePath stringByAppendingPathComponent:FU_HEAD_BUNDLE];
        NSData *headData = [NSData dataWithContentsOfFile:headPath];
        
        //获取文件路径
        NSString *filePath = [documentPath stringByAppendingPathComponent:avatar.name];
        
        [hairArray enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            FUItemModel *enumModel = (FUItemModel *)obj;
            NSString *hairPath = [enumModel.path stringByAppendingPathComponent:enumModel.bundle];
            NSData *hairData = [NSData dataWithContentsOfFile:hairPath];
            
            if (hairData != nil)
            {
                NSData *newHairData = [[fuPTAClient shareInstance]createHairWithHeadData:headData defaultHairData:hairData];
                NSString *newHairPath = [filePath stringByAppendingPathComponent:enumModel.name];
                
                [newHairData writeToFile:newHairPath atomically:YES];
            }
        }];
    });
}

#pragma mark ------ 加载形象 ------
/// 加载形象
/// @param avatar 形象模型
- (void)reloadAvatarToControllerWithAvatar:(FUAvatar *)avatar
{
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    
    // 销毁上一个 avatar
    if (self.currentAvatars.count != 0)
    {
        FUAvatar *lastAvatar = self.currentAvatars.firstObject ;
        [lastAvatar destroyAvatarResouce];
        [self.currentAvatars removeObject:lastAvatar];
    }
    
    if (avatar == nil)
    {
        dispatch_semaphore_signal(signal) ;
        return ;
    }

    // 创建新的
    [avatar loadAvatarToController];
    [avatar openHairAnimation];
    mItems[2] = self.defalutQController ;
    
    // 保存到当前 render 列表里面
    [self.currentAvatars addObject:avatar];
    [avatar loadIdleModePose];
    dispatch_semaphore_signal(signal);
}

/**
 
 普通模式下 新增 Avatar render
 
 @param avatar 新增的 Avatar
 */
- (void)addRenderAvatar:(FUAvatar *)avatar {
//gcz
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    
    // 创建新的
    [avatar loadAvatarToController];
    // 保存到当前 render 列表里面
    [self.currentAvatars addObject:avatar];
    
    mItems[2] = self.defalutQController;
    
    dispatch_semaphore_signal(signal);
}

/**
 普通模式下 删除 Avatar render
 
 @param avatar 需要删除的 avatar
 */
- (void)removeRenderAvatar:(FUAvatar *)avatar
{//gcz
    if (avatar == nil || ![self.currentAvatars containsObject:avatar])
    {
        NSLog(@"---- avatar is nil or avatar is not rendering ~");
        return;
    }
    
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    [avatar setCurrentAvatarIndex:avatar.currentInstanceId];    // 设置当前avatar的nama序号，使所有的操作都基于当前avatar
    
    NSInteger index = [self.currentAvatars indexOfObject:avatar];
    
    [avatar destroyAvatarResouce];
    [self.currentAvatars removeObject:avatar];
    
    dispatch_semaphore_signal(signal);
}




/**
 在 AR滤镜 模式下切换 Avatar   不销毁controller
 
 @param avatar Avatar
 */
- (void)reloadRenderAvatarInARModeInSameController:(FUAvatar *)avatar {
    
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    
    // 销毁上一个 avatar
    if (self.currentAvatars.count != 0) {
        FUAvatar *lastAvatar = self.currentAvatars.firstObject;
        [lastAvatar destroyAvatarResouce];
        [self.currentAvatars removeObject:lastAvatar];
        arItems[0] = 0;
    }
    
    if (avatar == nil) {
        dispatch_semaphore_signal(signal);
        return;
    }
    
    arItems[0] = [avatar loadAvatarWithARMode];
    [avatar closeHairAnimation];
    // 保存到当前 render 列表里面
    [self.currentAvatars addObject:avatar];
    
    dispatch_semaphore_signal(signal);
}



#pragma mark ------ 数据处理 ------
/// 获取颜色编号
/// @param key 颜色类别
/// @param dict 形象信息字典
- (NSInteger)getIndexWithColorTypeKey:(NSString *)key andDict:(NSDictionary *)dict
{
    NSString *levelKey = [key stringByAppendingString:@"Level"];
    
    if ([dict.allKeys containsObject:levelKey])
    {
        return [dict[levelKey] integerValue];
    }
    
    NSString *indexKey = [key stringByAppendingString:@"ColorIndex"];
    
    if ([dict.allKeys containsObject:indexKey])
    {
        return [dict[indexKey] integerValue];
    }
    
    NSString *colorKey = [key stringByAppendingString:@"_color"];
    
    if ([dict.allKeys containsObject:colorKey])
    {
        FUP2AColor *color = [FUP2AColor colorWithDict:dict[colorKey]];
        NSArray *currentColorArray = self.colorDict[colorKey];
        
        __block NSInteger index = 0;
        
        [currentColorArray enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            FUP2AColor *enumColor = (FUP2AColor *)obj;
            
            if ([enumColor colorIsEqualTo:color])
            {
                index = idx;
                *stop = YES;
            }
        }];
        return index+1;
    }

    return 1;
}

/// 获取道具模型
/// @param key 道具类别
/// @param dict 形象信息字典
- (FUItemModel *)getItemModelWithKey:(NSString *)key andDict:(NSDictionary *)dict
{
    NSArray *array = [FUManager shareInstance].itemsDict[key];
    NSString *bundle = dict[key];
    
    if (bundle == nil)
    {
        return  array[0];
    }
    
    __block FUItemModel *model;
    
    [array enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {

        FUItemModel *currentModel = (FUItemModel *)obj;
        
        if ([currentModel.name rangeOfString:bundle].length > 0)
        {
            model = currentModel;
            *stop = YES;
        }
    }];
    
    if (model == nil)
    {
        return array[0];
    }
    
    return model;
}


// 获取默认眼镜
- (FUItemModel *)getGlassesNameWithShape:(int)shape rim:(int)rim male:(BOOL)male{
    
    __block FUItemModel *model = self.itemsDict[TAG_FU_ITEM_GLASSES][0];
    NSString *glass;
    if (shape == 1 && rim == 0) {
        glass = male ? @"male_glass_1" : @"female_glass_1";
    }else if (shape == 0 && rim == 0){
        glass = male ? @"male_glass_2" : @"female_glass_2";
    }else if (shape == 1 && rim == 1){
        glass = male ? @"male_glass_8" : @"female_glass_8";
    }else if (shape == 1 && rim == 2){
        glass = male ? @"male_glass_15" : @"female_glass_15";
    }
    
    [self.itemsDict[TAG_FU_ITEM_GLASSES] enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        
        FUItemModel *enumModel = (FUItemModel *)obj;
        
        if ([enumModel.name isEqualToString:glass])
        {
            model = enumModel;
            *stop = YES;
        }
        
    }];
    
    return model;
}

// 获取Q风格默认眼镜
- (FUItemModel *)getQGlassesNameWithShape:(int)shape rim:(int)rim male:(BOOL)male
{
    __block FUItemModel *model = self.itemsDict[TAG_FU_ITEM_GLASSES][0];
    
    NSString * glassesName = @"glass_13";
    
    if (shape == 1 && rim == 0)
    {
        glassesName = @"glass_14";
    }
    else if (shape == 0 && rim == 0)
    {
        glassesName = @"glass_2";
    }
    else if (shape == 1 && rim == 1)
    {
        glassesName = @"glass_8";
    }
    else if (shape == 1 && rim == 2)
    {
        glassesName = @"glass_15";
    }
    
    
    [self.itemsDict[TAG_FU_ITEM_GLASSES] enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        
        FUItemModel *enumModel = (FUItemModel *)obj;
        
        if ([enumModel.name isEqualToString:glassesName])
        {
            model = enumModel;
            *stop = YES;
        }
        
    }];
    
    return model;
}

- (FUItemModel *)gethairNameWithNum:(int)num andGender:(FUGender)g
{
    NSArray *hairArray = self.itemsDict[TAG_FU_ITEM_HAIR];
    FUItemModel *model = hairArray[0];
    
    NSMutableArray *matchHairArray = [[NSMutableArray alloc]init];

        [hairArray enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            FUItemModel *enumModel = (FUItemModel *)obj;
            
            if ([enumModel.gender_match integerValue] == g&&[enumModel.label containsObject:[NSNumber numberWithInt:num]])
            {
                [matchHairArray addObject:enumModel];
            }
        }];
    
    if (matchHairArray.count == 1)
    {
        model = matchHairArray[0];
    }
    else if (matchHairArray.count > 1)
    {
        model = matchHairArray[arc4random() % matchHairArray.count];
    }
    
    return model;
}

// 根据 beardLabel 获取 beard name
- (FUItemModel *)getBeardNameWithNum:(int)num Qtype:(BOOL)q male:(BOOL)male
{
    NSArray *beardArray = self.itemsDict[TAG_FU_ITEM_BEARD];
    FUItemModel *model = beardArray[0];
    
    NSMutableArray *matchBeardArray = [[NSMutableArray alloc]init];
    
    [beardArray enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        FUItemModel *enumModel = (FUItemModel *)obj;
        
        if ([enumModel.gender_match integerValue] == male&&[enumModel.label containsObject:[NSNumber numberWithInt:num]])
        {
            [matchBeardArray addObject:enumModel];
        }
    }];
    
    if (matchBeardArray.count == 1)
    {
        model = matchBeardArray[0];
    }
    else if (matchBeardArray.count == 1)
    {
        model = matchBeardArray[arc4random() % matchBeardArray.count];
    }
    
    return model;
}

#pragma mark ------ 拍照识别 ------
static float DetectionAngle = 20.0;
static float CenterScale = 0.3;
/**
 拍摄检测
 
 @return 检测结果
 */
- (NSString *)photoDetectionAction
{
    // 1、保证单人脸输入
    int faceNum = [self faceCaptureGetResultIsFace];
    if (faceNum != 1)
    {
        return @" 请保持1个人输入  ";
    }

    // 2、保证正脸
    float rotation[4];
    [FURenderer getFaceInfo:0 name:@"rotation" pret:rotation number:4];
    
    float xAngle = atanf(2 * (rotation[3] * rotation[0] + rotation[1] * rotation[2]) / (1 - 2 * (rotation[0] * rotation[0] + rotation[1] * rotation[1]))) * 180 / M_PI;
    float yAngle = asinf(2 * (rotation[1] * rotation[3] - rotation[0] * rotation[2])) * 180 / M_PI;
    float zAngle = atanf(2 * (rotation[3] * rotation[2] + rotation[0] * rotation[1]) / (1 - 2 * (rotation[1] * rotation[1] + rotation[2] * rotation[2]))) * 180 / M_PI;
    
    if (xAngle < -DetectionAngle || xAngle > DetectionAngle
        || yAngle < -DetectionAngle || yAngle > DetectionAngle
        || zAngle < -DetectionAngle || zAngle > DetectionAngle)
    {
        return @" 识别失败，需要人物正脸完整出镜哦~  ";
    }
    
    // 3、保证人脸在中心区域
    CGPoint faceCenter = [self getFaceCenterInFrameSize:frameSize];
    
    if (faceCenter.x < 0.5 - CenterScale / 2.0 || faceCenter.x > 0.5 + CenterScale / 2.0
        || faceCenter.y < 0.4 - CenterScale / 2.0 || faceCenter.y > 0.4 + CenterScale / 2.0)
    {
        return @" 请将人脸对准虚线框  ";
    }
    
    // 4、夸张表情
    float expression[46];
    [FURenderer getFaceInfo:0 name:@"expression" pret:expression number:46];
    
    for (int i = 0; i < 46; i ++)
    {
        if (expression[i] > 1)
        {
            return @" 请保持面部无夸张表情  ";
        }
    }
    
    // 5、光照均匀
    // 6、光照充足
    if (lightingValue < -1.0) {
        return @" 光线不充足  ";
    }
    
    return @" 完美  ";
}

/**
 获取人脸矩形框
 
 @return 人脸矩形框
 */
- (CGRect)getFaceRect
{
    float faceRect[4];
    int ret = [FURenderer faceCaptureGetResultFaceBbox:self.faceCapture faceN:0 buffer:faceRect length:4];
    if (!ret)
    {
        return CGRectZero;
    }
    // 计算出中心点的坐标值
    CGFloat centerX = (faceRect[0] + faceRect[2]) * 0.5;
    CGFloat centerY = (faceRect[1] + faceRect[3]) * 0.5;
    
    // 将坐标系转换成以左上角为原点的坐标系
    centerX = frameSize.width - centerX;
    centerY = frameSize.height - centerY;
    
    CGRect rect = CGRectZero;
    if (frameSize.width < frameSize.height)
    {
        CGFloat w = frameSize.width;
        rect.size = CGSizeMake(w, w);
        rect.origin = CGPointMake(0, centerY - w/2.0);
    }
    else
    {
        CGFloat w = frameSize.height;
        rect.size = CGSizeMake(w, w);
        rect.origin = CGPointMake(centerX - w / 2.0, 0);
    }
    
    CGPoint origin = rect.origin;
    if (origin.x < 0)
    {
        origin.x = 0;
    }
    if (origin.y < 0)
    {
        origin.y = 0;
    }
    rect.origin = origin;
    
    return rect;
}

/**获取图像中人脸中心点*/
- (CGPoint)getFaceCenterInFrameSize:(CGSize)frameSize
{
    static CGPoint preCenter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        preCenter = CGPointMake(0.49, 0.5);
    });
    
    // 获取人脸矩形框，坐标系原点为图像右下角，float数组为矩形框右下角及左上角两个点的x,y坐标（前两位为右下角的x,y信息，后两位为左上角的x,y信息）
    float faceRect[4];
    int ret = [FURenderer faceCaptureGetResultFaceBbox:self.faceCapture faceN:0 buffer:faceRect length:4];
    
    if (ret == 0)
    {
        return preCenter;
    }
    
    // 计算出中心点的坐标值
    CGFloat centerX = (faceRect[0] + faceRect[2]) * 0.5;
    CGFloat centerY = (faceRect[1] + faceRect[3]) * 0.5;
    
    // 将坐标系转换成以左上角为原点的坐标系
    centerX = frameSize.width - centerX;
    centerX = centerX / frameSize.width;
    
    centerY = frameSize.height - centerY;
    centerY = centerY / frameSize.height;
    
    CGPoint center = CGPointMake(centerX, centerY);
    
    preCenter = center;
    
    return center;
}


#pragma mark ----- AR
/**
 进入 AR滤镜 模式
 -- 会切换 controller 所在句柄
 */
- (void)enterARMode
{
    if (self.currentAvatars.count != 0)
    {
        FUAvatar *avatar = self.currentAvatars.firstObject;
        int handle = [avatar getControllerHandle];
        arItems[0] = handle;
    }
}

/**
 设置最多识别人脸的个数
 
 @param num 最多识别人脸个数
 */
- (void)setMaxFaceNum:(int)num
{
    [FURenderer setMaxFaces:num];
}

/**
 切换 AR滤镜
 
 @param filePath AR滤镜 路径
 */
- (void)reloadARFilterWithPath:(NSString *)filePath
{
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    
    if (arItems[1] != 0) {
        [FURenderer destroyItem:arItems[1]];
        arItems[1] = 0;
    }
    
    if (filePath == nil || ![[NSFileManager defaultManager] fileExistsAtPath:filePath])
    {
        dispatch_semaphore_signal(signal);
        return;
    }
    
    arItems[1] = [FURenderer itemWithContentsOfFile:filePath];
    
    dispatch_semaphore_signal(signal);
}


/**
 在正常渲染avatar的模式下，切换AR滤镜
 
 @param filePath  滤镜 路径
 */
- (void)reloadFilterWithPath:(NSString *)filePath
{
    dispatch_semaphore_wait(signal, DISPATCH_TIME_FOREVER);
    
    if (mItems[3] != 0)
    {
        [FURenderer destroyItem:mItems[3]];
        mItems[3] = 0;
    }
    
    if (filePath == nil || ![[NSFileManager defaultManager] fileExistsAtPath:filePath])
    {
        dispatch_semaphore_signal(signal);
        return;
    }
    
    mItems[3] = [FURenderer itemWithContentsOfFile:filePath];
    
    dispatch_semaphore_signal(signal);
}

#pragma mark ------ SET/GET
/// 设置形象风格
/// @param avatarStyle 形象风格
-(void)setAvatarStyle:(FUAvatarStyle)avatarStyle
{
    _avatarStyle = avatarStyle;
    [self loadSubData];
}

/*
 背景道具是否存在
 
 @return 是否存在
 */
- (BOOL)isBackgroundItemExist
{
    return mItems[1] != 0;
}

-(NSString *)appVersion
{
    NSString* versionStr = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    return [NSString stringWithFormat:@"DigiMe Art v%@",versionStr];
}

-(NSString *)sdkVersion
{
    NSString *version = [[fuPTAClient shareInstance] getVersion];
    return [NSString stringWithFormat:@"SDK v%@", version];
}

@end
