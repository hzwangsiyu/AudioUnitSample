//
//  AUSAudioUnitGraph.m
//  AudioUnitSample
//
//  Created by Warren Moore on 1/23/13.
//  Copyright (c) 2013 Auerhaus Development, LLC. All rights reserved.
//

#define CA_PREFER_FIXED_POINT 0

#import "AUSAudioUnitGraph.h"

static const AudioUnitElement inputElement = 1;
static const AudioUnitElement outputElement = 0;

static OSStatus InputRenderCallback(void *inRefCon,
									AudioUnitRenderActionFlags *ioActionFlags,
									const AudioTimeStamp *inTimeStamp,
									UInt32 inBusNumber,
									UInt32 inNumberFrames,
									AudioBufferList *ioData);
static void CheckStatus(OSStatus status, NSString *message, BOOL fatal);

@interface AUSAudioUnitGraph ()
@property(nonatomic, assign) AUGraph auGraph;
@property(nonatomic, assign) AUNode ioNode;
@property(nonatomic, assign) AUNode mixerNode;
@property(nonatomic, assign) AUNode timePitchNode;
@property(nonatomic, assign) AudioUnit ioUnit;
@property(nonatomic, assign) AudioUnit mixerUnit;
@property(nonatomic, assign) AudioUnit timePitchUnit;
@end

@implementation AUSAudioUnitGraph

- (id)init
{
	if((self = [super init]))
	{
		_sampleRate = 44100.0;
		[self createAudioUnitGraph];
	}

	return self;
}

- (void)dealloc
{
	[self destroyAudioUnitGraph];
}

- (AudioStreamBasicDescription)noninterleavedPCMFormatWithChannels:(NSInteger)channels
{
	size_t bytesPerSample = sizeof(AudioUnitSampleType);

	AudioStreamBasicDescription asbd;
	bzero(&asbd, sizeof(asbd));
	asbd.mSampleRate = _sampleRate;
	asbd.mFormatID = kAudioFormatLinearPCM;
	asbd.mFormatFlags = kAudioFormatFlagsAudioUnitCanonical;
	asbd.mBitsPerChannel = 8 * bytesPerSample;
	asbd.mBytesPerFrame = bytesPerSample;
	asbd.mBytesPerPacket = bytesPerSample;
	asbd.mFramesPerPacket = 1;
	asbd.mChannelsPerFrame = channels;

	return asbd;
}

- (void)createAudioUnitGraph
{
	OSStatus status = noErr;

	NSDate *date = [NSDate date];

	status = NewAUGraph(&_auGraph);
	CheckStatus(status, @"Could not create a new AUGraph", YES);

	[self addAudioUnitNodes];

	status = AUGraphOpen(_auGraph);
	CheckStatus(status, @"Could not open AUGraph", YES);

	[self getUnitsFromNodes];

	[self setAudioUnitProperties];

	[self makeNodeConnections];

	CAShow(_auGraph);

	status = AUGraphInitialize(_auGraph);
	CheckStatus(status, @"Could not initialize AUGraph", YES);

	NSTimeInterval dur = [date timeIntervalSinceNow] * -1000.0;

	NSLog(@"Took %0.3f milliseconds to build AUGraph", dur);
	exit(0);
}

- (void)addAudioUnitNodes
{
	OSStatus status = noErr;

	AudioComponentDescription ioDescription;
	bzero(&ioDescription, sizeof(ioDescription));
	ioDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	ioDescription.componentType = kAudioUnitType_Output;
	ioDescription.componentSubType = kAudioUnitSubType_RemoteIO;

	status = AUGraphAddNode(_auGraph, &ioDescription, &_ioNode);
	CheckStatus(status, @"Could not add I/O node to AUGraph", YES);

	AudioComponentDescription mixerDescription;
	bzero(&mixerDescription, sizeof(mixerDescription));
	mixerDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	mixerDescription.componentType = kAudioUnitType_Mixer;
	mixerDescription.componentSubType = kAudioUnitSubType_MultiChannelMixer;

	status = AUGraphAddNode(_auGraph, &mixerDescription, &_mixerNode);
	CheckStatus(status, @"Could not add mixer node to AUGraph", YES);

	AudioComponentDescription timePitchDescription;
	bzero(&timePitchDescription, sizeof(timePitchDescription));
	timePitchDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
	timePitchDescription.componentType = kAudioUnitType_FormatConverter;
	timePitchDescription.componentSubType = kAudioUnitSubType_NewTimePitch;

	status = AUGraphAddNode(_auGraph, &timePitchDescription, &_timePitchNode);
	CheckStatus(status, @"Could not add time-pitch node to AUGraph", YES);
}

- (void)getUnitsFromNodes
{
	OSStatus status = noErr;
	
	status = AUGraphNodeInfo(_auGraph, _ioNode, NULL, &_ioUnit);
	CheckStatus(status, @"Could not retrieve node info for I/O node", YES);

	status = AUGraphNodeInfo(_auGraph, _mixerNode, NULL, &_mixerUnit);
	CheckStatus(status, @"Could not retrieve node info for mixer node", YES);

	status = AUGraphNodeInfo(_auGraph, _timePitchNode, NULL, &_timePitchUnit);
	CheckStatus(status, @"Could not retrieve node info for time-pitch node", YES);
}

- (void)setAudioUnitProperties
{
	OSStatus status = noErr;
	AudioStreamBasicDescription stereoFormat = [self noninterleavedPCMFormatWithChannels:2];
	AudioStreamBasicDescription monoFormat = [self noninterleavedPCMFormatWithChannels:1];

	status = AudioUnitSetProperty(_ioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputElement,
								  &monoFormat, sizeof(monoFormat));
	CheckStatus(status, @"Could not set stream format on I/O unit output scope", YES);

	UInt32 enableIO = 1;
	status = AudioUnitSetProperty(_ioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputElement,
								  &enableIO, sizeof(enableIO));
	CheckStatus(status, @"Could not enable I/O on I/O unit input scope", YES);

	UInt32 mixerElementCount = 2;
	status = AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0,
								  &mixerElementCount, sizeof(mixerElementCount));
	CheckStatus(status, @"Could not set element count on mixer unit input scope", YES);

	status = AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
								  &stereoFormat, sizeof(stereoFormat));
	CheckStatus(status, @"Could not set stream format on mixer unit input scope, element 1", YES);

	AURenderCallbackStruct callbackStruct;
	callbackStruct.inputProc = &InputRenderCallback;
	callbackStruct.inputProcRefCon = (__bridge void *)self;
	status = AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 1,
								  &callbackStruct, sizeof(callbackStruct));
	CheckStatus(status, @"Could not set render callback on mixer input scope", YES);

	status = AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0,
								  &_sampleRate, sizeof(_sampleRate));
	CheckStatus(status, @"Could not set sample rate on mixer unit output scope", YES);

	status = AudioUnitSetProperty(_timePitchUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0,
								  &monoFormat, sizeof(monoFormat));
	CheckStatus(status, @"Could not set stream format on time-shift unit output scope", YES);
}

- (void)makeNodeConnections
{
	OSStatus status = noErr;

	status = AUGraphConnectNodeInput(_auGraph, _ioNode, 1, _timePitchNode, 0);
	CheckStatus(status, @"Could not connect I/O node output to time-pitch node input", YES);

	status = AUGraphConnectNodeInput(_auGraph, _timePitchNode, 0, _mixerNode, 0);
	CheckStatus(status, @"Could not connect time-pitch node output to mixer node input", YES);

	status = AUGraphConnectNodeInput(_auGraph, _mixerNode, 0, _ioNode, 0);
	CheckStatus(status, @"Could not connect mixer node output to I/O node input", YES);
}

- (void)destroyAudioUnitGraph
{
	AUGraphStop(_auGraph);
	AUGraphUninitialize(_auGraph);
	AUGraphClose(_auGraph);
	AUGraphRemoveNode(_auGraph, _timePitchNode);
	AUGraphRemoveNode(_auGraph, _mixerNode);
	AUGraphRemoveNode(_auGraph, _ioNode);
	DisposeAUGraph(_auGraph);
	_ioUnit = NULL;
	_mixerUnit = NULL;
	_mixerNode = 0;
	_ioNode = 0;
	_auGraph = NULL;
}

- (void)start
{
	OSStatus status = AUGraphStart(_auGraph);
	CheckStatus(status, @"Could not start AUGraph", YES);
}

- (void)stop
{
	OSStatus status = AUGraphStop(_auGraph);
	CheckStatus(status, @"Could not stop AUGraph", YES);
}

- (void)setMixerPan:(Float32)mixerPan
{
	_mixerPan = mixerPan;

	OSStatus status = AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Pan, kAudioUnitScope_Input, 0,
											_mixerPan, 0);
	CheckStatus(status, @"Could not set pan on mixer unit", NO);
}

- (void)setPitchAdjustment:(Float32)pitchAdjustment
{
	_pitchAdjustment = pitchAdjustment;

	OSStatus status = AudioUnitSetParameter(_timePitchUnit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0,
											_pitchAdjustment, 0);
	CheckStatus(status, @"Could not adjust pitch of time-pitch unit", NO);
}

- (OSStatus)renderData:(AudioBufferList *)data
		   atTimeStamp:(const AudioTimeStamp *)timeStamp
			forElement:(UInt32)element
		  numberFrames:(UInt32)frames
				 flags:(AudioUnitRenderActionFlags *)flags
{
	AudioUnitSampleType *leftSamples = data->mBuffers[0].mData;
	AudioUnitSampleType *rightSamples = data->mBuffers[1].mData;

	NSTimeInterval sampleTime = timeStamp->mSampleTime / self.sampleRate;
	NSTimeInterval sampleDuration = 1 / self.sampleRate;

	for(size_t i = 0; i < frames; ++i)
	{
		leftSamples[i] = rightSamples[i] = 0.05 * cos(2 * M_PI * 440 * sampleTime);
		sampleTime += sampleDuration;
	}

	return noErr;
}

@end

static OSStatus InputRenderCallback(void *inRefCon,
									AudioUnitRenderActionFlags *ioActionFlags,
									const AudioTimeStamp *inTimeStamp,
									UInt32 inBusNumber,
									UInt32 inNumberFrames,
									AudioBufferList *ioData)
{
	AUSAudioUnitGraph *graph = (__bridge id)inRefCon;
	return [graph renderData:ioData
				 atTimeStamp:inTimeStamp
				  forElement:inBusNumber
				numberFrames:inNumberFrames
					   flags:ioActionFlags];
}

static void CheckStatus(OSStatus status, NSString *message, BOOL fatal)
{
	if(status != noErr)
	{
		char fourCC[16];
		*(UInt32 *)fourCC = CFSwapInt32HostToBig(status);
		fourCC[4] = '\0';

        if(isprint(fourCC[0]) && isprint(fourCC[1]) && isprint(fourCC[2]) && isprint(fourCC[3]))
			NSLog(@"%@: %s", message, fourCC);
		else
			NSLog(@"%@: %ld", message, status);

		if(fatal)
			exit(-1);
	}
}