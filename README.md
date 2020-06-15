# Transcoder

Transcoder是一个将 *MPEG4、amr_nb* 转码为 *H.264、AAC* 的类。因项目容量太大（ffmpeg的库和测试音频），github上传不了，如需要完整可运行的项目请在[issues](https://github.com/chenjiangchuan/Transcoding/issues)留邮箱。

## 使用

*YMTransCoder* 使用单例模式创建对象：

```
YMTransCoder *coder = [YMTransCoder shared];
```

#### 转码的方法

```
/// 转码（包括编码方式、码率、分辨率、采样率、采样格式等的转换）
/// @param src 需要转码的文件路径
/// @param dst 转码完成的文件路径
/// @param processBlock 转码进度回调
/// @param completionBlock 转码完成回调
- (void)transCoderWithSrc:(NSString *)src
                     dst:(NSString *)dst
            processBlock:(void (^)(float process))processBlock
         completionBlock:(void (^)(NSError *error))completionBlock;
```

#### 使用

```
- (void)transCodingButtonAction:(UIButton *)sender {
    // 获取noplayer.mp4的路径
    NSString *str = [[NSBundle mainBundle] resourcePath];
    NSString *inFilePath = [NSString stringWithFormat:@"%@/%@.mp4", str, self.inputFileNameTextField.text];
    
    NSString *documentsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *outFilePath = [NSString stringWithFormat:@"%@/%@.mp4", documentsPath, self.inputFileNameTextField.text];
    
    self.textField.text = @"正在转码...";
    
    // 判断是否可以保存到本地相册
    if (UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(inFilePath)) {
        NSLog(@"可以保存到本地相册");
        UISaveVideoAtPathToSavedPhotosAlbum(inFilePath, self, @selector(saveVideoWithPath:didFinishSavingWithError:contextInfo:), nil);
    } else {
        NSLog(@"不可以保存到本地相册");
        // 转码
        [[YMTransCoder shared] transCoderWithSrc:inFilePath dst:outFilePath processBlock:^(float process) {
            self.textField.text = [NSString stringWithFormat:@"转码中 %.2f%%", process * 100];
        } completionBlock:^(NSError * _Nonnull error) {
            if (!error) {
                self.textField.text = @"转码成功";
                UISaveVideoAtPathToSavedPhotosAlbum(outFilePath, self, @selector(saveVideoWithPath:didFinishSavingWithError:contextInfo:), nil);
            } else {
                NSLog(@"%@", error);
                self.textField.text = error.localizedDescription;
                if (error.code == YMTransCoderReturnTypeEncodeAudioFaile) {
                    [self transCodingButtonAction:self.transcodeButton];
                }
            }
        }];
    }
    NSLog(@"%@", outFilePath);
}
```

这里需要注意，如果`error.code`返回的是`YMTransCoderReturnTypeEncodeAudioFaile`，说明音频编码为AAC时有问题（低概率出现），这个是编码器的BUG。所以这里需要再次调用*YMTransCoder*的转码方法：

```
if (error.code == YMTransCoderReturnTypeEncodeAudioFaile) {
    [self transCodingButtonAction:self.transcodeButton];
}
```
##### 保存到本地相册的回调

```
- (void)saveVideoWithPath:(NSString *)videoPath didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo {
    if (error) {
        self.textField.text = @"保存视频失败";
        NSLog(@"保存视频失败%@", error.localizedDescription);
    } else {
        self.textField.text = @"保存视频成功";
    }
}
```

##### 其他方法

```
// 取消转码
- (IBAction)cacelTranscodeAction:(id)sender {
    [[YMTransCoder shared] cancel];
}

// 暂停转码
- (IBAction)pauseTranscodeAction:(id)sender {
    [[YMTransCoder shared] pause];
}

// 继续转码（暂停转码后）
- (IBAction)startTranscodeAction:(id)sender {
    [[YMTransCoder shared] start];
}
```

## 遇到的问题

这个转码Demo是在[nldzsz的ffmpeg-demo](https://github.com/nldzsz/ffmpeg-demo)基础上修改的。

FFmpeg API使用可以参考官网的[例子](http://ffmpeg.org/doxygen/trunk/examples.html)，非常有帮助，里面的例子囊括了绝大部分API的使用方法。

常用的结构体：AVFormatContext、AVStream、AVCodec、AVCodecContext、AVPacket、AVFrame。

在了解这些结构体前，必须清楚的知道音视频封装、编码的概念。我们通常说：这个视频是MP4格式，或者AVI、RMVB、MKV等，这都是指视频的封装格式，而编码格式我们需要右击属性才看到，常见的视频编码格式有：MPEG4、H.264、H.265。

* AVFormatContext结构体代表一个音视频文件；
* AVStream就是这个音视频流信息，比如一个音视频文件有两个流信息：一个是音频流、一个是视频流，如果该视频还有字幕，那么就有第三个流；
* AVCodec和AVCodecContext是描述编/解码器的信息；
* AVPacket是AVStream中的一帧数据（编码后）；
* AVFrame是裸流的一帧数据（解码后）。

进入正题，在测试阶段，发现同一个音视频文件转码时，开始AAC编码时会偶尔报错：Input contains (near) NaN/+-Inf [aac @]  frames left in the queue on closing。

这个是给AAC编码器的音频数据格式不对，比如FFmpeg的aac编码库需要音频的样本格式是`AV_SAMPLE_FMT_FLTP`。因为这是非必现，所以在编码过程中加入了一个判断：如果开始编码AAC失败，则重新进行编码，知道编码成功。经过测试，如果开始编码失败，重新开始的次数通过为2~3次（用户无感知）。

在对另一个音视频转码时，音频转码又报了另外一个错误：[aac @ 000001cfc2717200] more samples than frame size (avcodec_encode_audio2)。

从FFmpeg源码`encode.c`可以找到这个打印信息：

```
if (avctx->codec->capabilities & AV_CODEC_CAP_SMALL_LAST_FRAME) {
	if (frame->nb_samples > avctx->frame_size) {
		av_log(avctx, AV_LOG_ERROR, "more samples than frame size (avcodec_encode_audio2)\n");
		ret = AVERROR(EINVAL);
		goto end;
	}
}
```

AAC编码器一次编码一帧数据，而一帧数据大小是有限制的（1024），但是解码得到的每一帧AVFrame数据大于1024，就这就会报错。

如何解决呢？网上都是给思路，我在`YMTransCoder.mm`中的`- (int)decodeAudioWithPacket:(AVPacket *)packet`中实现音频数据缓存。 大致处理逻辑（详细流程请参考代码）：

1. 初始化音频fifo缓冲区：`av_audio_fifo_alloc`；
2. 从输入音视频文件AVFormatContext中读取一帧AVPacket，并判断是否是音频数据，如果是音频数据，解码为AVFrame裸流；
3. 判断fifo缓冲区是否有1024字节的数据，如果没有跳4，如果有跳5；
4. 将解码后的AVFrame写入fifo缓冲区；
5. 如果fifo缓冲区数据大于1024字节，则读取1024字节数据；如果小于1024字节，则读取fifo缓冲区全部的数据；
6. 将从fifo读取的AVFrame交给AAC编码器进行编码。


这是目前遇到的两个比较棘手的问题，后面还需要兼容更多的音视频格式，要填的坑还有很多，Demo会持续更新。