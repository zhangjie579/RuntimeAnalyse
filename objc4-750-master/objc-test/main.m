//
//  main.m
//  objc-test
//
//  Created by GongCF on 2018/12/16.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "TesObject.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
//        Class newClass = objc_allocateClassPair(objc_getClass("NSObject"), "newClass", 0);
//                objc_registerClassPair(newClass);
//        id newObject = [[newClass alloc]init];
//        Class testClass = objc_allocateClassPair([NSObject class], "TestObject", 0);
//        BOOL isAdded = class_addIvar(testClass, "password", sizeof(NSString *), log2(sizeof (NSString *)), @encode(NSString *));
//        objc_registerClassPair(testClass);
//        if (isAdded) {
//            id object = [[testClass alloc] init]; [object setValue:@"lxz" forKey:@"password"];
//        }
//        class_getMethodImplementation
        TesObject *newObject = [[TesObject alloc]init];
        
        [newObject performSelector:@selector(funck)];
    }
//    NSLog(@"%@",NSThread.callStackSymbols);
    return 0;
}



