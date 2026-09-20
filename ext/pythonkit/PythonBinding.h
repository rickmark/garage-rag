//
// Created by Rick Mark on 9/19/26.
//

#ifndef GARAGE_PYTHONBINDING_H
#define GARAGE_PYTHONBINDING_H

#if __has_include(<Python/Python.h>)
#import <Python/Python.h>
#elif __has_include(<Python.h>)
#import <Python.h>
#elif __has_include(<python3.13/Python.h>)
#import <python3.13/Python.h>
#else
#import <Python.h>
#endif

#endif //GARAGE_PYTHONBINDING_H
