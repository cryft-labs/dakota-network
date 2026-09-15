"""Normalize solc storage layouts while ignoring unstable compiler type IDs."""
def shape(layout):
    def normalized(key):
        value=layout['types'][key]
        result={k:value[k] for k in ('label','encoding','numberOfBytes')}
        for k in ('base','key','value'):
            if k in value:result[k]=normalized(value[k])
        if 'members' in value:result['members']=[(m['label'],m['slot'],m['offset'],normalized(m['type'])) for m in value['members']]
        return result
    return [(x['label'],x['slot'],x['offset'],normalized(x['type'])) for x in layout['storage']]
