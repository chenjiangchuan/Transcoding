//
//  YMTransCoder.h
//  Transcoding
//
//  Created by chenjiangchuan on 2020/6/2.
//  Copyright © 2020 RiversChan. All rights reserved.
//
//  Description: 转码
//  History:
//    1. 2020/6/2 [chenjiangchuan]: 创建文件;
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 转码返回值类型
typedef NS_ENUM(int, YMTransCoderReturnType) {
    /** 初始化音频缓冲区失败 */
    YMTransCoderReturnTypeInitAudioFifoFaile = -11,
    /** 编码视频失败 */
    YMTransCoderReturnTypeEncodeVideoFaile = -10,
    /** 编码音频失败 */
    YMTransCoderReturnTypeEncodeAudioFaile = -9,
    /** 向输出文件中写头失败 */
    YMTransCoderReturnTypeWriteOutputHeaderFail = -8,
    /** 打开输出文件指针失败 */
    YMTransCoderReturnTypeOpenOutputPbFail = -7,
    /** 为输出添加音频流失败 */
    YMTransCoderReturnTypeAddAudioStreamFail = -6,
    /** 为输出添加视频流失败 */
    YMTransCoderReturnTypeAddVideoStreamFail = -5,
    /** 打开输出流失败 */
    YMTransCoderReturnTypeOpenOutputFileFail = -4,
    /** 打开输入流失败 */
    YMTransCoderReturnTypeOpenInputFileFail = -3,
    /** 正在转码 */
    YMTransCoderReturnTypeTranscoding = -2,
    /** 取消转码 */
    YMTransCoderReturnTypeCancel = -1,
    /** 转码成功 */
    YMTransCoderReturnTypeSuccess = 0,
};

@interface YMTransCoder : NSObject

/// 单例
+ (instancetype)shared;

/// 转码（包括编码方式、码率、分辨率、采样率、采样格式等的转换）
/// @param src 需要转码的文件路径
/// @param dst 转码完成的文件路径
/// @param processBlock 转码进度回调
/// @param completionBlock 转码完成回调
- (void)transCoderWithSrc:(NSString *)src
                     dst:(NSString *)dst
            processBlock:(void (^)(float process))processBlock
         completionBlock:(void (^)(NSError *error))completionBlock;

/// 取消转码
- (void)cancel;

/// 暂停转码
- (void)pause;

/// 暂停后继续转码
- (void)start;

@end

NS_ASSUME_NONNULL_END
