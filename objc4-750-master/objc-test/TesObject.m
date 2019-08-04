//
//  TesObject.m
//  objc-test
//
//  Created by 张杰 on 2018/12/24.
//

#import "TesObject.h"

@implementation TesObject

- (instancetype)init {
    if (self = [super init]) {
        NSLog(@"%@", NSStringFromClass([self class]));
        NSLog(@"%@", NSStringFromClass([super class]));
        
        
        
    }
    return self;
}

@end
