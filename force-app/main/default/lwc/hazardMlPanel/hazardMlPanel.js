import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getHazard from '@salesforce/apex/CRHazardMLController.getHazard';
import runMlPrediction from '@salesforce/apex/CRHazardMLController.runMlPrediction';

export default class HazardMlPanel extends LightningElement {
    @api recordId;
    @track mlOutput;
    isRunning = false;
    signal;
    media = [];
    wiredResult;

    @wire(getHazard, { recordId: '$recordId' })
    wiredHazard(result) {
        this.wiredResult = result;
        if (result.data) {
            this.signal = result.data.signal;
            this.media = result.data.media || [];
            this.mlOutput = this.formatOutput(result.data.mlOutput);
        }
    }

    get hasSignal() {
        return this.signal != null;
    }

    get images() {
        return this.media.filter((m) => m.Media_Type__c !== 'Redirect' && m.Media_URL__c);
    }

    get links() {
        return this.media.filter((m) => m.Media_Type__c === 'Redirect' && m.Media_URL__c);
    }

    get riskVariant() {
        if (!this.signal) {
            return 'base';
        }
        switch (this.signal.Risk_Level__c) {
            case 'Critical':
                return 'error';
            case 'High':
                return 'warning';
            default:
                return 'inverse';
        }
    }

    async handleRunMl() {
        this.isRunning = true;
        try {
            const output = await runMlPrediction({ recordId: this.recordId });
            this.mlOutput = this.formatOutput(output);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'ML prediction complete',
                    variant: 'success'
                })
            );
            await refreshApex(this.wiredResult);
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'ML prediction failed',
                    message: (error && error.body && error.body.message) || 'Unknown error',
                    variant: 'error'
                })
            );
        } finally {
            this.isRunning = false;
        }
    }

    formatOutput(raw) {
        if (!raw) {
            return null;
        }
        try {
            return JSON.stringify(JSON.parse(raw), null, 2);
        } catch (e) {
            return raw;
        }
    }
}