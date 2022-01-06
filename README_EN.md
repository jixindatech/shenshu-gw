# shenshu-gw
English | [中文](./README.md)

# dependencies
- dependencies: libinjection needs python 2.x environment.
- hyperscan dev also needs to be installed early.

## configuration
- config.yaml as the main configuration file，gw.yaml is local configuration data file(do not edit unless you know what will happend)，
- ss.yaml is event log configuration file for shenshu，support file，rsyslog and kafka way to configure, please ignore zt.yaml。
- es.conf under doc/rsyslog directory is the example of rsyslog.
- doc/*_mapping.json is data structer for elasticsearch, should be deploied at advanced。
- ### config.yaml introduction
    - rsyslog is event log address.
    - redis is cache data for mapping configuration.
    - config_type is the way of configuration data be imported， and the one is yaml stored at gw.yaml file.
    the other is redis
- ### ss.yaml introduction
    - *_log,file represents event log will be found in error.log， rsyslog attributes exist shows event log will be
  sent to rsyslog by config.yaml rsyslog configuration. kafka implies event log will be sent to kafka.
    - file just for test

## install
- make init generates nginx.conf file.
- make deps generates dependencies.
- when local test, deps should be copied to luajit path.
- ./bin/gw.lua runtime directory is pwd， others run directory is /usr/loca/gw.
- when make install, do not forget deps to be copied.

## simple flow
![image](doc/images/flow.png)

## Contributing
welecome issue and star

## Discussion Group
QQ gruop: 254210748

##License
Unlicense

