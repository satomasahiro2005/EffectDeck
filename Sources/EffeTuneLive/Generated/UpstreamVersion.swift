//  UpstreamVersion.swift
//  Tools/gen_version.py が作る。手で直さないこと。
//
//  積んでいる EffeTune の dsp/ 自体の版（Vendor/effetune の dsp-v* タグ）。
//  **アプリの版とは別の事実。**あちらは出した日で、
//  EffeTune アプリ全体の版（package.json）とも別。
//
//  ETUpstreamAppVersion は積んでいる EffeTune アプリ全体の版（Vendor/effetune/package.json）。
//  公式の PC は hello の返事に dsp の版を出さず、この版だけを出す。食い違いの表示にだけ使う。
//  読めなければ空。

let ETUpstreamVersion = "0.13.0"
let ETUpstreamAppVersion = "2.13.0"
