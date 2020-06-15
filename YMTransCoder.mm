//
//  YMTransCoder.m
//  Transcoding
//
//  Created by chenjiangchuan on 2020/6/2.
//  Copyright © 2020 RiversChan. All rights reserved.
//
//  Description: 转码
//  History:
//    1. 2020/6/2 [chenjiangchuan]: 创建文件;
//

#import "YMTransCoder.h"

#include <vector>

// ffmpeg
extern "C" {
#include <libavutil/avutil.h>
#include <libavutil/error.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <libavutil/channel_layout.h>
#include <libavutil/audio_fifo.h>
}

// 转码参数配置
typedef struct TransCoderParameter {
    // 是否和源文件参数一致
    bool copy;
    union {
        enum AVCodecID codec_id;
        enum AVPixelFormat pix_fmt;
        enum AVSampleFormat smp_fmt;
        int64_t i64_val;
        int     i32_val;
    } par_val;
} TransCoderParameter;

// 输入文件封装格式上下文
AVFormatContext *in_fmt_ctx = NULL;
// 输出文件封装格式上下文
AVFormatContext *out_fmt_ctx = NULL;

// 音频解码器上下文
AVCodecContext *audio_decode_ctx = NULL;
// 视频解码器上下文
AVCodecContext *video_decode_ctx = NULL;

// 音频编码器上下文
AVCodecContext *audio_encode_ctx = NULL;
// 视频编码器上下文
AVCodecContext *video_encode_ctx = NULL;

// 音视频重采样
SwrContext *swr_ctx = NULL;
// 视频重采样
struct SwsContext *sws_ctx = NULL;

// 音频是否需要重采样
BOOL audio_need_convert = NO;
// 视频是否需要重采样
BOOL video_need_convert = NO;
// 音频是否需要转码
BOOL audio_need_transcode = NO;
// 视频是否需要转码
BOOL video_need_transcode = NO;

// 音频解码后的原始流（pcm）
AVFrame *audio_decode_frame = NULL;
// 视频解码后的原始流（YUV）
AVFrame *video_decode_frame = NULL;

// 音频编码前的原始流（pcm）
AVFrame *audio_encode_frame = NULL;
// 视频编码前的原始流（YUV）
AVFrame *video_encode_frame = NULL;

// 输入音频流在输入流中的下标位置
int audio_in_stream_index = -1;
// 输入视频流在输入流中的下标位置
int video_in_stream_index = -1;

// 输出音频流在输出流中的下标位置
int audio_out_stream_index = -1;
// 输出视频流在输出流中的下标位置
int video_out_stream_index = -1;

// 音频的pts（显示时间戳）
int64_t audio_pts = 0;
// 视频pts（显示时间戳）
int64_t video_pts = 0;

// 记录最近一次的音频pts
int64_t last_audio_pts = 0;
// 记录最近一次的视频pts
int64_t last_video_pts = 0;

// 源音/视编解码器的id
enum AVCodecID src_audio_id;
enum AVCodecID src_video_id;

// 目的音视频的编/解码器ID
TransCoderParameter dst_audio_id;
TransCoderParameter dst_video_id;

// 目的音视频的比特率
TransCoderParameter dst_audio_bit_rate;
TransCoderParameter dst_video_bit_rate;

// 目的音频的通道布局
TransCoderParameter dst_channel_layout;
// 目的音频的采样率
TransCoderParameter dst_sample_rate;
// 目的音频的采样格式
TransCoderParameter dst_sample_fmt;

// 目的视频的宽/高
TransCoderParameter dst_width;
TransCoderParameter dst_height;
// 目的视频的帧率
TransCoderParameter dst_fps;
// 目的视频的像素格式
TransCoderParameter dst_pix_fmt;

// 用于缓存视频编码后的AVPacket
std::vector<AVPacket *> videoCache;
// 用于缓存音频编码后的AVPacket
std::vector<AVPacket *> audioCache;

AVAudioFifo *fifo = NULL;
// 音频数据需要写入fifo
BOOL audio_need_fifo = NO;

// 取消转码
BOOL cancle_transcoding = NO;
// 暂停转码
BOOL pause_transcoding = NO;

const char *GCD_QUEUE_NAME = "com.yamei.concurrent";

@interface YMTransCoder ()

/** 正在转码 */
@property (nonatomic, assign) BOOL isRuning;
/** 开始转码 */
@property (nonatomic, assign) BOOL isBegin;
/** 文件转码时长 */
@property (nonatomic, assign) long long fileDuration;
/** 转码进度回调 */
@property (nonatomic, copy) void (^processBlock)(float process);
/** 转码完成回调 */
@property (nonatomic, copy) void (^completionBlock)(NSError *error);

@end

@implementation YMTransCoder

#pragma mark -
#pragma mark - Single
static YMTransCoder *_instance = nil;
+ (instancetype)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _instance = [[YMTransCoder alloc] init];
        
    });
    return _instance;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    @synchronized (self) {
        if (_instance == nil) {
            _instance = [super allocWithZone:zone];
            return _instance;
        }
    }
    return _instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (id)mutableCopy {
    return self;
}

#pragma mark -
#pragma mark - Public Methods
- (void)transCoderWithSrc:(NSString *)src
                      dst:(NSString *)dst
             processBlock:(void (^)(float process))processBlock
          completionBlock:(void (^)(NSError *error))completionBlock {
    self.processBlock = processBlock;
    self.completionBlock = completionBlock;
    self.isBegin = NO;
    cancle_transcoding = NO;
    pause_transcoding = NO;
    
    __weak typeof(self) weakSelf = self;
    dispatch_queue_t queue = dispatch_queue_create(GCD_QUEUE_NAME, DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
        __strong typeof(self) strongSelf = weakSelf;
        YMTransCoderReturnType ret = [strongSelf transCoderWithSrc:src dst:dst];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ret == YMTransCoderReturnTypeTranscoding) {
                self.isRuning = YES;
                strongSelf.completionBlock([strongSelf customErrorWithReturnType:ret]);
            } else {
                self.isRuning = NO;
                if (ret != YMTransCoderReturnTypeSuccess) {
                    strongSelf.completionBlock([strongSelf customErrorWithReturnType:ret]);
                } else {
                    strongSelf.completionBlock(nil);
                }
            }
        });
    });
}

/// 取消转码
- (void)cancel {
    cancle_transcoding = YES;
}

/// 暂停转码
- (void)pause {
    pause_transcoding = YES;
}

/// 暂停后继续转码
- (void)start {
    pause_transcoding = NO;
}

#pragma mark -
#pragma mark - Private Methods
/// 转码（包括编码方式、码率、分辨率、采样率、采样格式等的转换）
/// @param src 需要转码的文件路径
/// @param dst 转码完成的文件路径
- (YMTransCoderReturnType)transCoderWithSrc:(NSString *)src dst:(NSString *)dst {
    if (self.isRuning) {
        return YMTransCoderReturnTypeTranscoding;
    }
    
    self.isRuning = YES;
    YMTransCoderReturnType ret = YMTransCoderReturnTypeSuccess;
    
    // 视频
    dst_video_id.copy = false;
    dst_video_id.par_val.codec_id = AV_CODEC_ID_H264;
    
    dst_width.copy = true;
    //    dst_width.par_val.i32_val = 1920;
    dst_height.copy = true;
    //    dst_height.par_val.i32_val = 540;
    
    dst_video_bit_rate.copy = true;
    //    dst_video_bit_rate.par_val.i64_val = 400000;
    
    dst_pix_fmt.copy = true;
    //    dst_pix_fmt.par_val.pix_fmt = AV_PIX_FMT_YUV420P;
    
    dst_fps.copy = true;
    //    dst_fps.par_val.i32_val = 50;
    
    video_need_transcode = YES; // 视频需要转码
    
    // 音频
    
    /*
     dst_audio_id =  Par_CodeId(false,AV_CODEC_ID_AAC);
     dst_audio_bit_rate = Par_Int64t(false,64000);
     dst_sample_rate = Par_Int32t(false,44100);    // 44.1khz
     dst_sample_fmt = Par_SmpFmt(true,AV_SAMPLE_FMT_FLTP);
     dst_channel_layout = Par_Int64t(true,AV_CH_LAYOUT_MONO);   // 双声道
     audio_need_transcode = true;
     */
    
    dst_audio_id.copy = false;
    dst_audio_id.par_val.codec_id = AV_CODEC_ID_AAC;
    
    dst_audio_bit_rate.copy = false;
    dst_audio_bit_rate.par_val.i64_val = 64000;
    
    dst_sample_rate.copy = false;
    dst_sample_rate.par_val.i32_val = 44100;
    
    dst_sample_fmt.copy = true;
    dst_sample_fmt.par_val.smp_fmt = AV_SAMPLE_FMT_FLTP;
    
    dst_channel_layout.copy = true;
    dst_channel_layout.par_val.i64_val = AV_CH_LAYOUT_MONO;
    
    audio_need_transcode = YES; // 音频需要转码
    
    // 打开输入文件流
    if (![self openInFile:src]) {
        printf("open in file failed\n");
        [self releaseSources];
        return YMTransCoderReturnTypeOpenInputFileFail;
    }
    
    // 打开输出文件流
    if (![self openOutFile:dst]) {
        printf("open out file failed\n");
        [self releaseSources];
        return YMTransCoderReturnTypeOpenOutputFileFail;
    }
    
    // 为输出文件流添加视频流
    if (video_in_stream_index != -1 && video_need_transcode) {
        if (![self addVideoStream]) {
            printf("add video stream failed\n");
            [self releaseSources];
            return YMTransCoderReturnTypeAddVideoStreamFail;
        }
    }
    
    // 为输出文件流添加音频流
    if (audio_in_stream_index != -1 && audio_need_transcode) {
        if (![self addAudioStream]) {
            printf("add audio stream failed\n");
            [self releaseSources];
            return YMTransCoderReturnTypeAddAudioStreamFail;
        }
    }
    
    if (audio_encode_ctx) {
        fifo = av_audio_fifo_alloc(audio_encode_ctx->sample_fmt, audio_encode_ctx->channels, 1);
        if (!fifo) {
            fprintf(stderr, "Could not allocate FIFO\n");
            [self releaseSources];
            return YMTransCoderReturnTypeInitAudioFifoFaile;
        }
    }
    
    // 打印输出信息
    av_dump_format(out_fmt_ctx, 0, [dst cStringUsingEncoding:NSUTF8StringEncoding], 1);
    
    // 打开输出流解封装的上下文
    if (!(out_fmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&out_fmt_ctx->pb, [dst cStringUsingEncoding:NSUTF8StringEncoding], AVIO_FLAG_WRITE) < 0) {
            printf("avio open failed\n");
            [self releaseSources];
            return YMTransCoderReturnTypeOpenOutputPbFail;
        }
    }
    
    // 写入头信息
    if (avformat_write_header(out_fmt_ctx, NULL) < 0) {
        printf("avformat write header failed\n");
        [self releaseSources];
        return YMTransCoderReturnTypeWriteOutputHeaderFail;
    }
    
    if (cancle_transcoding) {
        printf("cancle transcoding\n");
        [self releaseSources];
        return YMTransCoderReturnTypeCancel;
    }
    
    // 暂停转码，while空循环
    while (pause_transcoding) {}
    
    // 读取源文件中的音视频数据（AVPacket），然后进行解码（AVFrame）
    AVPacket *in_packet = av_packet_alloc();
    while (av_read_frame(in_fmt_ctx, in_packet) == 0) {
        // 没有取消转码
        if (!cancle_transcoding) {
            // 暂停转码，while空循环
            while (pause_transcoding) {}
            // 解码读出的视频数据
            if (in_packet->stream_index == video_in_stream_index && video_need_transcode) {
                if ([self decodeVideoWithPacket:in_packet] != 0) {
                    [self releaseSources];
                    return YMTransCoderReturnTypeEncodeVideoFaile;
                }
            }
            
            // 解码读出的音频数据
            if (in_packet->stream_index == audio_in_stream_index && audio_need_transcode) {
                if ([self decodeAudioWithPacket:in_packet] != 0) {
                    [self releaseSources];
                    return YMTransCoderReturnTypeEncodeAudioFaile;
                }
            }
            // 释放
            av_packet_unref(in_packet);
        } else {
            // 释放
            av_packet_unref(in_packet);
            printf("cancle transcoding\n");
            [self releaseSources];
            return YMTransCoderReturnTypeCancel;
        }
    }
    
    // 刷新解码缓冲区
    if (video_in_stream_index != -1 && video_need_transcode && !cancle_transcoding) {
        // 暂停转码，while空循环
        while (pause_transcoding) {}
        [self decodeVideoWithPacket:NULL];
    }
    
    if (audio_in_stream_index != -1 && audio_need_transcode && !cancle_transcoding) {
        // 暂停转码，while空循环
        while (pause_transcoding) {}
        [self decodeAudioWithPacket:NULL];
    }
    
    // 写尾部信息
    if (out_fmt_ctx && !cancle_transcoding) {
        // 暂停转码，while空循环
        while (pause_transcoding) {}
        av_write_trailer(out_fmt_ctx);
    }
    
    printf("success \n");
    
    [self releaseSources];
    
    if (cancle_transcoding) {
        return YMTransCoderReturnTypeCancel;
    }
    
    return ret;
}

/// 打开输入文件流
- (BOOL)openInFile:(NSString *)src {
    if (src.length <= 0) return NO;
    
    int ret = 0;
    const char *src_path = [src cStringUsingEncoding:NSUTF8StringEncoding];
    
    // 打开输入文件
    ret = avformat_open_input(&in_fmt_ctx, src_path, NULL, NULL);
    if (ret < 0) {
        printf("avformat open input failed\n");
        [self releaseSources];
        return NO;
    }
    
    // 找到输入流中的音视频流
    ret = avformat_find_stream_info(in_fmt_ctx, NULL);
    if (ret < 0) {
        printf("avformat find stream info failed:%d\n", ret);
        [self releaseSources];
        return NO;
    }
    
    // 输出输入流信息
    av_dump_format(in_fmt_ctx, 0, src_path, 0);
    
    // 查找对应的音视频流
    for (int i = 0; i < in_fmt_ctx->nb_streams; i++) {
        AVCodecParameters *codecpar = in_fmt_ctx->streams[i]->codecpar;
        // 视频
        if (codecpar->codec_type == AVMEDIA_TYPE_VIDEO && video_in_stream_index == -1) {
            src_video_id = codecpar->codec_id;
            video_in_stream_index = i;
        } else if (codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audio_in_stream_index == -1) {
            src_audio_id = codecpar->codec_id;
            audio_in_stream_index = i;
        }
    }
    
    // 获取总长度
    self.fileDuration = in_fmt_ctx->duration / 1000000 + 1;
    printf("fileDuration：%lld秒\n", self.fileDuration);
    
    return YES;
}

/// 打开输出文件流
- (BOOL)openOutFile:(NSString *)dst {
    if (dst.length <= 0) return NO;
    
    int ret = 0;
    const char *dst_path = [dst cStringUsingEncoding:NSUTF8StringEncoding];
    
    // 打开输出流
    ret = avformat_alloc_output_context2(&out_fmt_ctx, NULL, NULL, dst_path);
    if (ret < 0) {
        printf("avformat alloc output context2 failed\n");
        [self releaseSources];
        return NO;
    }
    
    // 检查目标编码方式是否支持
    // 视频  If no codec tag is found returns 0.
    if (video_in_stream_index != -1 && av_codec_get_tag(out_fmt_ctx->oformat->codec_tag, dst_video_id.par_val.codec_id) == 0) {
        printf("video tag not found\n");
        [self releaseSources];
        return NO;
    }
    
    // 音频
    if (audio_in_stream_index != -1 && av_codec_get_tag(out_fmt_ctx->oformat->codec_tag, dst_audio_id.par_val.codec_id) == 0) {
        printf("audio tag not found\n");
        [self releaseSources];
        return NO;
    }
    return YES;
}

/// 为输出文件天添加视频流
- (BOOL)addVideoStream {
    // 查找编码器
    AVCodec *codec = avcodec_find_encoder(dst_video_id.par_val.codec_id);
    if (!codec) {
        printf("video code can not found encoder\n");
        [self releaseSources];
        return NO;
    }
    
    // 在输出文件流中(AVFormatContext)中创建 Stream 通道
    AVStream *stream = avformat_new_stream(out_fmt_ctx, NULL);
    if (!stream) {
        printf("avformat new stream failed\n");
        [self releaseSources];
        return NO;
    }
    // 记录输出的视频流下标
    video_out_stream_index = stream->index;
    
    // 根据编码器创建编码器上下文
    video_encode_ctx = avcodec_alloc_context3(codec);
    if (!video_encode_ctx) {
        printf("avcodec alloc context3 failed\n");
        [self releaseSources];
        return NO;
    }
    
    // 设置编码器上下文相关的参数
    // 获取输入流的视频流参数
    AVCodecParameters *in_codecpar = in_fmt_ctx->streams[video_in_stream_index]->codecpar;
    // 编码器ID
    video_encode_ctx->codec_id = codec->id;
    // 码率
    video_encode_ctx->bit_rate = dst_video_bit_rate.copy ? in_codecpar->bit_rate : dst_video_bit_rate.par_val.i64_val;
    // 视频宽
    video_encode_ctx->width = dst_width.copy ? in_codecpar->width : dst_width.par_val.i32_val;
    // 视频高
    video_encode_ctx->height = dst_height.copy ? in_codecpar->height : dst_width.par_val.i32_val;
    // 帧率
    int fps = dst_fps.copy ? in_fmt_ctx->streams[video_in_stream_index]->r_frame_rate.num : dst_fps.par_val.i32_val;
    video_encode_ctx->framerate = (AVRational){fps, 1};
    // 时间基
    stream->time_base = (AVRational){1, video_encode_ctx->framerate.num};
    video_encode_ctx->time_base = stream->time_base;
    // I帧间隔，决定压缩率
    video_encode_ctx->gop_size = 12;
    // 设置像素格式
    enum AVPixelFormat want_pix_fmt = dst_pix_fmt.copy ? (enum AVPixelFormat)(in_codecpar->format) : dst_pix_fmt.par_val.pix_fmt;
    enum AVPixelFormat result_pix_fmt = [self selectPiexlFormatWithCodec:codec pixelFmt:want_pix_fmt];
    if (result_pix_fmt == AV_PIX_FMT_NONE) {
        printf("can not support pix fmt\n");
        [self releaseSources];
        return NO;
    }
    video_encode_ctx->pix_fmt = result_pix_fmt;
    
    // 每个I帧间B帧最大个数
    if (codec->id == AV_CODEC_ID_MPEG2VIDEO) {
        video_encode_ctx->max_b_frames = 2;
    }
    
    if (codec->id == AV_CODEC_ID_MPEG1VIDEO) {
        video_encode_ctx->mb_decision = 2;
    }
    
    // 是否需要重采样
    if (result_pix_fmt != (enum AVPixelFormat)in_codecpar->format ||
        video_encode_ctx->width != in_codecpar->width ||
        video_encode_ctx->height != in_codecpar->height) {
        video_need_convert = YES;
    }
    
    /*
     遇到问题：生成的mp4或者mov文件没有显示用于预览的小图片
     分析原因：之前代编码器器flags标记设置的为AVFMT_GLOBALHEADER(错了)，正确的值应该是AV_CODEC_FLAG_GLOBAL_HEADER
     解决思路：使用如下代码设置AV_CODEC_FLAG_GLOBAL_HEADER
     */
    if (out_fmt_ctx->oformat->flags & AVFMT_GLOBALHEADER) {
        video_encode_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    
    // x264编码
    if (video_encode_ctx->codec_id == AV_CODEC_ID_H264) {
        av_opt_set(video_encode_ctx->priv_data, "preset", "slow", 0);
        video_encode_ctx->flags |= AV_CODEC_FLAG2_LOCAL_HEADER;
    }
    
    int ret = 0;
    // 打开编码器
    ret = avcodec_open2(video_encode_ctx, video_encode_ctx->codec, NULL);
    if (ret < 0) {
        printf("video encode open failed:%d\n", ret);
        [self releaseSources];
        return NO;
    }
    
    // 将codec的参数复制到stream中
    ret = avcodec_parameters_from_context(stream->codecpar, video_encode_ctx);
    if (ret < 0) {
        printf("video avcodec parameters from context failed\n");
        [self releaseSources];
        return NO;
    }
    
    return YES;
}

/// 为输出文件流添加音频流
- (BOOL)addAudioStream {
    if (!out_fmt_ctx) {
        printf("audio out format null\n");
        [self releaseSources];
        return NO;
    }
    
    // 在输出文件流中(AVFormatContext)中创建 Stream 通道
    AVStream *stream = avformat_new_stream(out_fmt_ctx, NULL);
    if (!stream) {
        printf("avformat new stream failed\n");
        [self releaseSources];
        return NO;
    }
    
    // 记录输出流音频流的下标
    audio_out_stream_index = stream->index;
    
    // 获取输入流音频的参数
    AVCodecParameters *in_codecpar = in_fmt_ctx->streams[audio_in_stream_index]->codecpar;
    // 查找编码器
    AVCodec *codec = avcodec_find_encoder(dst_audio_id.par_val.codec_id);
    // 获取编码器上下文
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) {
        printf("audio codec context null\n");
        [self releaseSources];
        return NO;
    }
    
    // 设置音频参数
    // 采样率
    int want_sample_rate = dst_sample_rate.copy ? in_codecpar->sample_rate : dst_sample_rate.par_val.i32_val;
    int relt_sample_rate = [self selectSampleRataWithCodec:codec rate:want_sample_rate];
    if (relt_sample_rate == 0) {
        printf("can not support sample rate\n");
        [self releaseSources];
        return NO;
    }
    ctx->sample_rate = relt_sample_rate;
    
    // 采样格式
    enum AVSampleFormat want_sample_format = dst_sample_fmt.copy ? (enum AVSampleFormat)in_codecpar->format : dst_sample_fmt.par_val.smp_fmt;
    enum AVSampleFormat relt_sample_format = [self selectSampleFormatWithCodec:codec sampleFmt:want_sample_format];
    if (relt_sample_format == AV_SAMPLE_FMT_NONE) {
        printf("can not support sample fmt\n");
        [self releaseSources];
        return NO;
    }
    ctx->sample_fmt = relt_sample_format;
    
    // 声道格式
    int64_t want_ch = dst_channel_layout.copy ? in_codecpar->channel_layout : dst_channel_layout.par_val.i64_val;
    // 声道格式保持和源一样
    int64_t relt_ch = [self selectChannelLayoutWithCodec:codec layout:want_ch];
    if (!relt_ch) {
        printf("can not support channal layout\n");
        [self releaseSources];
        return NO;
    }
    ctx->channel_layout = relt_ch;
    
    // 声道数
    ctx->channels = av_get_channel_layout_nb_channels(ctx->channel_layout);
    // 编码后的码率
    ctx->bit_rate = dst_audio_bit_rate.copy ? in_codecpar->bit_rate : dst_audio_bit_rate.par_val.i32_val;
    // 设置时间基
    ctx->time_base = (AVRational){1, ctx->sample_rate};
    stream->time_base = ctx->time_base;
    
    // 保存
    audio_encode_ctx = ctx;
    
    // 设置编码的相关标记，这样进行封装的时候不会漏掉一些元信息
    if (out_fmt_ctx->oformat->flags & AVFMT_GLOBALHEADER) {
        audio_encode_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    }
    
    // 打开音频编码器
    int ret = avcodec_open2(ctx, codec, NULL);
    if (ret < 0) {
        printf("audio avcodec open failed\n");
        [self releaseSources];
        return NO;
    }
    
    // 判断是否需要重采样
    if (audio_encode_ctx->frame_size != in_codecpar->frame_size ||
        relt_sample_format != in_codecpar->format ||
        relt_ch != in_codecpar->channel_layout ||
        relt_sample_rate != in_codecpar->sample_rate) {
        audio_need_convert = YES;
    }
    
    // 将编码信息复制到音频流中
    ret = avcodec_parameters_from_context(stream->codecpar, ctx);
    if (ret < 0) {
        printf("audio copy audio stream failed\n");
        [self releaseSources];
        return NO;
    }
    
    // 初始化重采样
    if (audio_need_convert) {
        swr_ctx = swr_alloc_set_opts(NULL,
                                     ctx->channel_layout,
                                     (enum AVSampleFormat)ctx->sample_fmt,
                                     ctx->sample_rate,
                                     in_codecpar->channel_layout,
                                     (enum AVSampleFormat)in_codecpar->format,
                                     in_codecpar->sample_rate,
                                     0,
                                     NULL);
        ret = swr_init(swr_ctx);
        if (ret < 0) {
            printf("swr alloc set opts failed:%d\n", ret);
            [self releaseSources];
            return NO;
        }
    }
    
    return YES;
}

/// 解码视频数据
- (int)decodeVideoWithPacket:(AVPacket *)inpacket {
    if (src_video_id == AV_CODEC_ID_NONE) {
        printf("src has not video\n");
        return -1;
    }
    
    int ret = 0;
    if (!video_decode_ctx) {
        AVCodec *codec = avcodec_find_decoder(src_video_id);
        video_decode_ctx  = avcodec_alloc_context3(codec);
        if (!video_decode_ctx) {
            printf("video decodc context create failed\n");
            [self releaseSources];
            return -1;
        }
        
        // 设置解码参数
        AVCodecParameters *in_codecpar = in_fmt_ctx->streams[video_in_stream_index]->codecpar;
        ret = avcodec_parameters_to_context(video_decode_ctx, in_codecpar);
        if (ret < 0) {
            printf("avcodec parameters to context failed:%d\n", ret);
            [self releaseSources];
            return -1;
        }
        
        // 打开解码器
        ret = avcodec_open2(video_decode_ctx, codec, NULL);
        if (ret < 0) {
            printf("video open avcodec failed\n");
            [self releaseSources];
            return -1;
        }
    }
    
    if (!video_decode_frame) {
        video_decode_frame = av_frame_alloc();
    }
    
    // 暂停转码，while空循环
    while (pause_transcoding) {}
    // 解码
    if (inpacket && !inpacket->size && inpacket->data) {
//        inpacket->size =
    }
    ret = avcodec_send_packet(video_decode_ctx, inpacket);
    if (ret < 0) {
        printf("video avcodec send packet failed\n");
        [self releaseSources];
        return -1;
    }
    
    while (!cancle_transcoding) {
        // 暂停转码，while空循环
        while (pause_transcoding) {}
        // 从解码缓冲区接收解码后的数据
        if ((ret = avcodec_receive_frame(video_decode_ctx, video_decode_frame)) < 0) {
            if (ret == AVERROR_EOF) {
                // 解码缓冲区结束后，也要flush编码缓冲区
                [self encodeVideoWithFrame:NULL];
            }
            break;
        }
        
        // 如果需要重采样
        if (!video_encode_frame) {
            video_encode_frame = [self videoFrameWithPixFmt:video_encode_ctx->pix_fmt width:video_encode_ctx->width height:video_encode_ctx->height];
            if (!video_encode_frame) {
                printf("can not create video frame\n");
                [self releaseSources];
                return -1;
            }
        }
        
        if (video_need_convert) {
            if (!sws_ctx) {
                AVCodecParameters *in_codecpar = in_fmt_ctx->streams[video_in_stream_index]->codecpar;
                int dst_width = video_encode_ctx->width;
                int dst_height = video_encode_ctx->height;
                enum AVPixelFormat dst_pix_fmt = video_encode_ctx->pix_fmt;
                sws_ctx = sws_getContext(in_codecpar->width,
                                         in_codecpar->height,
                                         (enum AVPixelFormat)in_codecpar->format,
                                         dst_width,
                                         dst_height,
                                         (enum AVPixelFormat)dst_pix_fmt,
                                         SWS_BICUBIC,
                                         NULL,
                                         NULL,
                                         NULL);
                if (!sws_ctx) {
                    printf("sws get context failed\n");
                    [self releaseSources];
                    return -1;
                }
            }
            // 进行转换
            ret = sws_scale(sws_ctx, video_decode_frame->data, video_decode_frame->linesize, 0, video_decode_frame->height, video_encode_frame->data, video_encode_frame->linesize);
            if (ret < 0) {
                printf("sws scale failed\n");
                [self releaseSources];
                return -1;
            }
        } else {
            // 不需要重采样的话，就直接拷贝
            av_frame_copy(video_encode_frame, video_decode_frame);
        }
        
        /*
         遇到问题：warning, too many B-frames in a row
         分析原因：之前下面doEncodeVideo()函数传递的参数为video_de_frame,这个是解码之后直接得到的AVFrame，它本身就包含了
         相关和编码不符合的参数
         解决方案：重新创建一个AVFrame，将解码后得到的AVFrame的data数据拷贝过去。然后用这个作为编码的AVFrame
         */
        video_encode_frame->pts = video_pts;
        video_pts++;
        [self encodeVideoWithFrame:video_encode_frame];
    }
    return 0;
}

/// 解码音频数据
- (int)decodeAudioWithPacket:(AVPacket *)packet {
    int ret = 0;
    int finished = 0;
    
    if (!audio_decode_ctx) {
        AVCodec *codec = avcodec_find_decoder(src_audio_id);
        if (!codec) {
            printf("audio decoder not found\n");
            [self releaseSources];
            return -1;
        }
        
        audio_decode_ctx = avcodec_alloc_context3(codec);
        if (!audio_decode_ctx) {
            printf("audio devodec alloc context failed\n");
            [self releaseSources];
            return -1;
        }
        
        // 设置音频解码上下文
        AVCodecParameters *in_codecpar = in_fmt_ctx->streams[audio_in_stream_index]->codecpar;
        ret = avcodec_parameters_to_context(audio_decode_ctx, in_codecpar);
        if (ret < 0) {
            printf("audio set decodec context failed\n");
            [self releaseSources];
            return -1;
        }
        
        ret = avcodec_open2(audio_decode_ctx, codec, NULL);
        if (ret < 0) {
            printf("audio avcodec open2 failed\n");
            [self releaseSources];
            return -1;
        }
    }
    
    // 创建解码用的AVFrame
    if (!audio_decode_frame) {
        audio_decode_frame = av_frame_alloc();
    }
    
    ret = avcodec_send_packet(audio_decode_ctx, packet);
    if (ret < 0) {
        printf("audio avcodec_send_packet failed\n");
        [self releaseSources];
        return -1;
    }
    
    while (!cancle_transcoding) {
        // 暂停转码，while空循环
        while (pause_transcoding) {}
        if ((ret = avcodec_receive_frame(audio_decode_ctx, audio_decode_frame)) < 0) {
            if (ret == AVERROR_EOF) {
//                printf("audio decode finish\n");
                finished = 1;
                ret = [self encodeAudioWithFrame:NULL];
                printf("audio decode finish:%d\n", ret);
            }
            break;
        }
        
        // 创建编码器用的AVFrame
        if (!audio_encode_frame) {
            audio_encode_frame = [self audioFrameWithSmpfmt:audio_encode_ctx->sample_fmt ch_layout:audio_encode_ctx->channel_layout sample_rate:audio_encode_ctx->sample_rate nb_samples:audio_encode_ctx->frame_size];
            if (!audio_encode_frame) {
                printf("can not create audio frame\n");
                [self releaseSources];
                return -1;
            }
        }
        
        // 是否需要重采样
        // 为了避免数据污染，所以这里只需要要将解码后得到的AVFrame中data数据拷贝到编码用的audio_en_frame中，解码后的其它数据则丢弃
        int pts_num = 0;
        if (audio_need_convert) {
            int dst_nb_samples = (int)av_rescale_rnd(swr_get_delay(swr_ctx, audio_decode_frame->sample_rate) + audio_decode_frame->nb_samples,
                                                     audio_encode_ctx->sample_rate,
                                                     audio_decode_frame->sample_rate,
                                                     AV_ROUND_UP);
            if (dst_nb_samples != audio_encode_frame->nb_samples) {
                av_frame_free(&audio_encode_frame);
                audio_encode_frame = [self audioFrameWithSmpfmt:audio_encode_ctx->sample_fmt ch_layout:audio_encode_ctx->channel_layout sample_rate:audio_encode_ctx->sample_rate nb_samples:dst_nb_samples];
                if (!audio_encode_frame) {
                    printf("can not create audio frame 2 \n");
                    [self releaseSources];
                    return -1;
                }
            }
            
            /** 遇到问题：当音频编码方式不一致时转码后无声音
             *  分析原因：因为每个编码方式对应的AVFrame中的nb_samples不一样，所以再进行编码前要进行AVFrame的转换
             *  解决方案：进行编码前先转换
             */
            ret = swr_convert(swr_ctx, audio_encode_frame->data, dst_nb_samples, (const uint8_t **)audio_decode_frame->data, audio_decode_frame->nb_samples);
            if (ret < 0) {
                printf("swr convert failed:%d\n", ret);
                [self releaseSources];
                return -1;
            }
            pts_num = ret;
        } else {
            av_frame_copy(audio_encode_frame, audio_decode_frame);
            pts_num = audio_encode_frame->nb_samples;
        }
        

        printf("nb_samples = %d, frame_size = %d\n", audio_encode_frame->nb_samples, audio_encode_ctx->frame_size);
        
        // 暂停转码，while空循环
        while (pause_transcoding) {}
        
        if (audio_encode_frame->nb_samples > audio_encode_ctx->frame_size) {
            // 判断fifo是否有数据
            while (av_audio_fifo_size(fifo) < audio_encode_ctx->frame_size) {
                // 写到fifo缓冲区中
                ret = av_audio_fifo_realloc(fifo, av_audio_fifo_size(fifo) + audio_encode_frame->nb_samples);
                if (ret < 0) {
                    fprintf(stderr, "Could not reallocate FIFO\n");
                    return ret;
                }
                
                // 暂停转码，while空循环
                while (pause_transcoding) {}
                
                ret = av_audio_fifo_write(fifo, (void **)audio_encode_frame->data, audio_encode_frame->nb_samples);
                if (ret < audio_encode_frame->nb_samples) {
                    fprintf(stderr, "Could not write data to FIFO\n");
                    return AVERROR_EXIT;
                }
            }
            
            while (av_audio_fifo_size(fifo) >= audio_encode_ctx->frame_size) {
                const int frame_size = FFMIN(av_audio_fifo_size(fifo), audio_encode_ctx->frame_size);
                AVFrame *output_frame;
                output_frame = av_frame_alloc();
                if (!output_frame) {
                    fprintf(stderr, "Could not allocate output frame\n");
                    return AVERROR_EXIT;
                }
                
                output_frame->nb_samples     = frame_size;
                output_frame->channel_layout = audio_encode_ctx->channel_layout;
                output_frame->format         = audio_encode_ctx->sample_fmt;
                output_frame->sample_rate    = audio_encode_ctx->sample_rate;
                
                ret = av_frame_get_buffer(output_frame, 0);
                if (ret < 0) {
                    fprintf(stderr, "Could not allocate output frame samples (error '%s')\n",
                            av_err2str(ret));
                    av_frame_free(&output_frame);
                    return ret;
                }
                
                // 暂停转码，while空循环
                while (pause_transcoding) {}
                
                if (av_audio_fifo_read(fifo, (void **)output_frame->data, frame_size) < frame_size) {
                    fprintf(stderr, "Could not read data from FIFO\n");
                    av_frame_free(&output_frame);
                    return AVERROR_EXIT;
                }
                
                output_frame->pts = av_rescale_q(audio_pts, (AVRational){1,output_frame->sample_rate}, audio_decode_ctx->time_base);
                audio_pts += pts_num;
                
                ret = [self encodeAudioWithFrame:output_frame];
                if (ret != 0) return ret;
            }
        } else {
            /*
             遇到问题：得到的文件播放时音画不同步
             分析原因：由于音频的AVFrame的pts没有设置对；pts是基于AVCodecContext的时间基的时间，所以pts的设置公式：
             音频：pts  = (timebase.den/sample_rate)*nb_samples*index；  index为当前第几个音频AVFrame(索引从0开始)，nb_samples为每个AVFrame中的采样数
             视频：pts = (timebase.den/fps)*index；
             解决方案：按照如下代码方式设置AVFrame的pts
             */
            //        audio_en_frame->pts = audio_pts++;    // 造成了音画不同步的问题
            audio_encode_frame->pts = av_rescale_q(audio_pts, (AVRational){1,audio_encode_frame->sample_rate}, audio_decode_ctx->time_base);
            audio_pts += pts_num;
            ret = [self encodeAudioWithFrame:audio_encode_frame];
            if (ret != 0) return ret;
        }
    }
    return 0;
}

/// 编码视频
- (void)encodeVideoWithFrame:(AVFrame *)frame {
    int ret = 0;
    
    // 将解码后的AVFrame重新编码为AVPacket
    if ((ret = avcodec_send_frame(video_encode_ctx, frame)) < 0) {
        printf("video encode avcodec send frame\n");
        [self releaseSources];
        return;
    }
    
    while (!cancle_transcoding) {
        // 暂停转码，while空循环
        while (pause_transcoding) {}
        AVPacket *pkt = av_packet_alloc();
        if ((ret = avcodec_receive_packet(video_encode_ctx, pkt)) < 0) {
            break;
        }
        
        // 编码后的数据写入文件，这里需要重新调整pts、dts、duration
        AVStream *stream = out_fmt_ctx->streams[video_out_stream_index];
        av_packet_rescale_ts(pkt, video_encode_ctx->time_base, stream->time_base);
        pkt->stream_index = video_out_stream_index;
        
        [self writeToDiskWithPkt:pkt isVideo:YES];
    }
}

/// 编码音频
- (int)encodeAudioWithFrame:(AVFrame *)frame {
    int ret = 0;
    
    if ((ret = avcodec_send_frame(audio_encode_ctx, frame)) < 0) {
        printf("audio avcodec send frame failed\n");
        [self releaseSources];
        return -1;
    }
    
    while (!cancle_transcoding) {
        // 暂停转码，while空循环
        while (pause_transcoding) {}
        
        AVPacket *pkt = av_packet_alloc();
        
        if ((ret = avcodec_receive_packet(audio_encode_ctx, pkt)) < 0) break;
        
        AVStream *stream = out_fmt_ctx->streams[audio_out_stream_index];
        av_packet_rescale_ts(pkt, audio_encode_ctx->time_base, stream->time_base);
        pkt->stream_index = audio_out_stream_index;
        
        [self writeToDiskWithPkt:pkt isVideo:NO];
    }
    return 0;
}

/// 将编码后的数据写入磁盘
- (void)writeToDiskWithPkt:(AVPacket *)packet isVideo:(BOOL)isVideo {
    if (!packet) {
        printf("paket is null\n");
        return;
    }
    
    AVPacket *audio_pkt = NULL;
    AVPacket *video_pkt = NULL;
    AVPacket *swap_pkt = NULL;
    
    if (isVideo) video_pkt = packet;
    else audio_pkt = packet;
    
    // 为精确比较时间，先缓存一些数据
    if (last_video_pts == 0 && isVideo && videoCache.size() == 0) {
        videoCache.push_back(packet);
        last_video_pts = packet->pts;
        printf("还没有 %s 数据\n", audio_pts == 0 ? "audio" : "video");
        return;
    }
    
    if (last_audio_pts == 0 && !isVideo && audioCache.size() == 0) {
        videoCache.push_back(packet);
        last_audio_pts = packet->pts;
        printf("还没有 %s 数据\n", video_pts == 0 ? "audio" : "video");
        return;
    }
    
    // 已经有了缓存数据
    if (videoCache.size() > 0) {
        video_pkt = videoCache.front();
        if (isVideo) {
            videoCache.push_back(packet);
        }
    }
    
    if (audioCache.size() > 0) {
        audio_pkt = audioCache.front();
        if (!isVideo) {
            audioCache.push_back(packet);
        }
    }
    
    if (video_pkt) last_video_pts = video_pkt->pts;
    if (audio_pkt) last_audio_pts = audio_pkt->pts;
    
    // 两个都有，进行时间比较
    if (video_pkt && audio_pkt) {
        AVStream *audio_stream = out_fmt_ctx->streams[audio_out_stream_index];
        AVStream *video_stream = out_fmt_ctx->streams[video_out_stream_index];
        // 视频在后
        if (av_compare_ts(last_audio_pts, audio_stream->time_base, last_video_pts, video_stream->time_base) <= 0) {
            swap_pkt = audio_pkt;
            if (audioCache.size() > 0) {
                std::vector<AVPacket *>::iterator begin = audioCache.begin();
                audioCache.erase(begin);
            }
        } else {
            swap_pkt = video_pkt;
            if (videoCache.size() > 0) {
                std::vector<AVPacket *>::iterator begin = videoCache.begin();
                videoCache.erase(begin);
            }
        }
    } else if (audio_pkt) {
        swap_pkt = audio_pkt;
        if (audioCache.size() > 0) {
            std::vector<AVPacket *>::iterator begin = audioCache.begin();
            audioCache.erase(begin);
        }
    } else if (video_pkt) {
        swap_pkt = video_pkt;
        if (videoCache.size() > 0) {
            std::vector<AVPacket *>::iterator begin = videoCache.begin();
            videoCache.erase(begin);
        }
    }
    
    static int sum = 0;
    if (!isVideo) sum++;
    
    printf("%s pts %lld dts %lld du %lld a_size %lu v_size %lu sum %d\n", swap_pkt->stream_index == audio_in_stream_index ? "audio" : "video", swap_pkt->pts, swap_pkt->dts, swap_pkt->duration, audioCache.size(), videoCache.size(), sum);
    if (swap_pkt->stream_index == audio_in_stream_index || audio_in_stream_index == -1) {
        self.isBegin = YES;
        if (self.processBlock && self.fileDuration) {
            long long time = swap_pkt->pts / 10000;
//            printf("index %d, pts %lld, dts %lld\n", swap_pkt->stream_index,  swap_pkt->pts,  swap_pkt->dts);
            float process = time / (self.fileDuration * 1.00);
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(self) strongSelf = weakSelf;
                strongSelf.processBlock(process);
            });
        }
    }
    
    if ((av_interleaved_write_frame(out_fmt_ctx, swap_pkt)) < 0) {
        printf("av interleaved write frame failed\n");
    }
    
    av_packet_unref(swap_pkt);
}

/// 选择适合的像素格式
- (enum AVPixelFormat)selectPiexlFormatWithCodec:(AVCodec *)codec pixelFmt:(enum AVPixelFormat)fmt {
    enum AVPixelFormat retpixfmt = AV_PIX_FMT_NONE;
    enum AVPixelFormat defaltfmt = AV_PIX_FMT_YUV420P;
    const enum AVPixelFormat *fmts = codec->pix_fmts;
    while (*fmts != AV_PIX_FMT_NONE) {
        retpixfmt = *fmts;
        if (retpixfmt == fmt) {
            break;
        }
        fmts++;
    }
    
    if (retpixfmt != fmt && retpixfmt != AV_PIX_FMT_NONE && retpixfmt != defaltfmt) {
        return defaltfmt;
    }
    
    return retpixfmt;
}

/// 选择合适的音频采样率
- (int)selectSampleRataWithCodec:(AVCodec *)codec rate:(int)rate {
    int best_rate = 0;
    int deft_rate = 44100;
    bool surport = false;
    const int* p = codec->supported_samplerates;
    while (*p) {
        best_rate = *p;
        if (*p == rate) {
            surport = true;
            break;
        }
        p++;
    }
    
    if (best_rate != rate && best_rate != 0 && best_rate != deft_rate) {
        return deft_rate;
    }
    
    return best_rate;
}

/// 选择合适的音频采样格式
- (enum AVSampleFormat)selectSampleFormatWithCodec:(AVCodec *)codec sampleFmt:(enum AVSampleFormat)fmt {
    enum AVSampleFormat retfmt = AV_SAMPLE_FMT_NONE;
    enum AVSampleFormat deffmt = AV_SAMPLE_FMT_FLTP;
    const enum AVSampleFormat * fmts = codec->sample_fmts;
    while (*fmts != AV_SAMPLE_FMT_NONE) {
        retfmt = *fmts;
        if (retfmt == fmt) {
            break;
        }
        fmts++;
    }
    
    if (retfmt != fmt && retfmt != AV_SAMPLE_FMT_NONE && retfmt != deffmt) {
        return deffmt;
    }
    
    return retfmt;
}

/// 选择合适的声道格式
- (int64_t)selectChannelLayoutWithCodec:(AVCodec *)codec layout:(int64_t)ch_layout {
    uint64_t best_ch_layout = AV_CH_LAYOUT_STEREO;
    const uint64_t *p = codec->channel_layouts;
    if (p == NULL) {
        return AV_CH_LAYOUT_STEREO;
    }
    int best_ch_layouts = 0;
    while (*p) {
        int layouts = av_get_channel_layout_nb_channels(*p);
        if (*p == ch_layout) {
            return *p;
        }
        
        if (layouts > best_ch_layouts) {
            best_ch_layout = *p;
            best_ch_layouts = layouts;
        }
        p++;
    }
    return best_ch_layout;
}

/// 创建视频的AVFrame
- (AVFrame *)videoFrameWithPixFmt:(enum AVPixelFormat)pixfmt width:(int)width height:(int)height {
    AVFrame *video_en_frame = av_frame_alloc();
    video_en_frame->format = pixfmt;
    video_en_frame->width = width;
    video_en_frame->height = height;
    int ret = 0;
    if ((ret = av_frame_get_buffer(video_en_frame, 0)) < 0) {
        printf("video get frame buffer fail %d\n",ret);
        return NULL;
    }
    
    if ((ret =  av_frame_make_writable(video_en_frame)) < 0) {
        printf("video av_frame_make_writable fail %d\n",ret);
        return NULL;
    }
    
    return video_en_frame;
}

/// 创建音频的AVFrame
- (AVFrame *)audioFrameWithSmpfmt:(enum AVSampleFormat)smpfmt ch_layout:(int64_t)ch_layout sample_rate:(int)sample_rate nb_samples:(int)nb_samples {
    AVFrame * audio_en_frame = av_frame_alloc();
    // 根据采样格式，采样率，声道类型以及采样数分配一个AVFrame
    audio_en_frame->sample_rate = sample_rate;
    audio_en_frame->format = smpfmt;
    audio_en_frame->channel_layout = ch_layout;
    audio_en_frame->nb_samples = nb_samples;
    int ret = 0;
    if ((ret = av_frame_get_buffer(audio_en_frame, 0)) < 0) {
        printf("audio get frame buffer fail %d\n",ret);
        return NULL;
    }
    
    if ((ret =  av_frame_make_writable(audio_en_frame)) < 0) {
        printf("audio av_frame_make_writable fail %d\n",ret);
        return NULL;
    }
    
    return audio_en_frame;
}

/// 释放资源
- (void)releaseSources {
    if (in_fmt_ctx) {
        avformat_close_input(&in_fmt_ctx);
        in_fmt_ctx = NULL;
    }
    
    if (out_fmt_ctx) {
        avformat_free_context(out_fmt_ctx);
        out_fmt_ctx = NULL;
    }
    
    if (video_encode_ctx) {
        avcodec_free_context(&video_encode_ctx);
        video_encode_ctx = NULL;
    }
    
    if (audio_encode_ctx) {
        avcodec_free_context(&audio_encode_ctx);
        audio_encode_ctx = NULL;
    }
    
    if (video_decode_ctx) {
        avcodec_free_context(&video_decode_ctx);
        video_decode_ctx = NULL;
    }
    
    if (audio_decode_ctx) {
        avcodec_free_context(&audio_decode_ctx);
        audio_decode_ctx = NULL;
    }
    
    if (video_decode_frame) {
        av_frame_free(&video_decode_frame);
        video_decode_frame = NULL;
    }
    
    if (audio_decode_frame) {
        av_frame_free(&audio_decode_frame);
    }
    
    if (video_encode_frame) {
        av_frame_free(&video_encode_frame);
        video_encode_frame = NULL;
    }
    
    if (audio_encode_frame) {
        av_frame_free(&audio_encode_frame);
        audio_encode_frame = NULL;
    }
    
    if (swr_ctx) {
        swr_free(&swr_ctx);
        swr_ctx = NULL;
    }
    
    if (sws_ctx) {
        sws_freeContext(sws_ctx);
        sws_ctx = NULL;
    }
    
    if (videoCache.size() > 0) {
        videoCache.clear();
        std::vector<AVPacket *>().swap(videoCache);
    }
    
    if (audioCache.size() > 0) {
        audioCache.clear();
        std::vector<AVPacket *>().swap(audioCache);
    }

    if (fifo) {
        av_audio_fifo_free(fifo);
        fifo = NULL;
    }
    
    audio_need_convert = NO;
    video_need_convert = NO;
    audio_need_transcode = NO;
    video_need_transcode = NO;
    audio_in_stream_index = -1;
    video_in_stream_index = -1;
    audio_out_stream_index = -1;
    video_out_stream_index = -1;
    audio_pts = 0;
    video_pts = 0;
    last_audio_pts = 0;
    last_video_pts = 0;
    cancle_transcoding = NO;
    pause_transcoding = NO;
    audio_need_fifo = NO;
}

/// 自定义错误信息
/// @param returnType 返回值
- (NSError *)customErrorWithReturnType:(YMTransCoderReturnType)returnType {
    NSString *domain = @"com.yamei.transconding";
    NSString *localizedDescription = NULL;
    switch (returnType) {
        case YMTransCoderReturnTypeEncodeAudioFaile:
            localizedDescription = @"编码音频失败（可手动再次点击转码）";
            break;
        case YMTransCoderReturnTypeWriteOutputHeaderFail:
            localizedDescription = @"向输出文件中写头失败";
            break;
        case YMTransCoderReturnTypeOpenOutputPbFail:
            localizedDescription = @"打开输出文件指针失败";
            break;
        case YMTransCoderReturnTypeAddAudioStreamFail:
            localizedDescription = @"为输出添加音频流失败";
            break;
        case YMTransCoderReturnTypeAddVideoStreamFail:
            localizedDescription = @"为输出添加视频流失败";
            break;
        case YMTransCoderReturnTypeOpenOutputFileFail:
            localizedDescription = @"打开输出流失败";
            break;
        case YMTransCoderReturnTypeOpenInputFileFail:
            localizedDescription = @"打开输入流失败";
            break;
        case YMTransCoderReturnTypeTranscoding:
            localizedDescription = @"正在转码，请稍后再试";
            break;
        case YMTransCoderReturnTypeCancel:
            localizedDescription = @"取消了转码";
            break;
        case YMTransCoderReturnTypeEncodeVideoFaile:
            localizedDescription = @"编码视频失败";
            break;
        default:break;
    }
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:localizedDescription forKey:NSLocalizedDescriptionKey];
    return [NSError errorWithDomain:domain code:returnType userInfo:userInfo];
}

@end
